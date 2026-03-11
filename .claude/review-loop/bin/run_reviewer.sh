#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"
require_cmd jq
require_cmd codex

job_name=""
codex_model=""
dry_run="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --job-name)
      job_name="${2:-}"
      shift 2
      ;;
    --codex-model)
      codex_model="${2:-}"
      shift 2
      ;;
    --dry-run)
      dry_run="1"
      shift
      ;;
    *)
      die "未対応の引数です: $1"
      ;;
  esac
done

[[ -n "$job_name" ]] || die "--job-name を指定してください"
ensure_job_exists "$job_name"

round_number="$(current_round "$job_name")"
[[ "$round_number" -gt 0 ]] || die "先に Claude のラウンドを記録してください"

target_round_dir="$(round_dir "$job_name" "$round_number")"
summary_json="$target_round_dir/claude_summary.json"
changed_files_txt="$target_round_dir/changed_files.txt"
[[ -f "$summary_json" ]] || die "claude_summary.json が見つかりません"
[[ -f "$changed_files_txt" ]] || die "changed_files.txt が見つかりません"

goal_text="$(cat "$(goal_file "$job_name")")"
summary_text="$(cat "$target_round_dir/claude_summary.md")"
quality_gate="$(jq '.quality_gate' "$summary_json")"

batch_index="1"
batch_count="0"
batch_tmp="$(mktemp)"
generated_any="0"

process_batch() {
  local index="$1"
  local batch_file="$2"
  local prompt_path="$target_round_dir/reviewer_batch_${index}.prompt.md"
  local output_path="$target_round_dir/reviewer_batch_${index}.json"
  local stdout_log="$target_round_dir/reviewer_batch_${index}.stdout.log"
  local stderr_log="$target_round_dir/reviewer_batch_${index}.stderr.log"
  local file_block
  local prompt
  local -a command

  file_block="$(sed 's/^/- /' "$batch_file")"
  prompt="$(cat <<EOF
\`AGENTS.md\`、\`docs/ARCHITECTURE.md\`、\`docs/REVIEW_RULES.md\`、\`docs/design/current/clabotch_design_doc_v11.md\` に従って read-only コードレビューをしてください。

このレビューでは次を禁止します。
- ファイル編集・作成・削除
- テスト実行
- build / analyze / dependency install
- supervisor / judge の代行

ユーザー要求:
$goal_text

Claude の今回ラウンド要約:
$summary_text

Claude が申告した品質ゲート:
$quality_gate

レビュー対象ファイル:
$file_block

出力ルール:
- JSON のみを返す
- Markdown コードフェンスは使わない
- \`overall_grade\` は \`S/A/B/C\`
- \`critical_count\` は重大指摘件数
- \`findings\` は severity の高い順に並べる
- \`next_action\` は \`approved\` / \`fix_and_rerun\` / \`needs_human\`

レビュー観点:
- セキュリティ
- パフォーマンス
- 保守性
- 設計・アーキテクチャ
- 型安全性
- テスタビリティ
EOF
)"
  printf '%s\n' "$prompt" > "$prompt_path"

  command=(codex -a never --sandbox read-only)
  if [[ -n "$codex_model" ]]; then
    command+=(-m "$codex_model")
  fi
  command+=(exec -C "$REPO_ROOT" --output-schema "$SCHEMAS_DIR/reviewer.schema.json" -o "$output_path" -)

  if [[ "$dry_run" == "1" ]]; then
    echo "[dry-run] reviewer batch $index prompt: $prompt_path"
    printf '%s\n' "${command[*]}"
    return 0
  fi

  if ! printf '%s' "$prompt" | "${command[@]}" > "$stdout_log" 2> "$stderr_log"; then
    die "reviewer batch $index に失敗しました: $stderr_log"
  fi
}

while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  printf '%s\n' "$path" >> "$batch_tmp"
  batch_count="$((batch_count + 1))"
  if [[ "$batch_count" -eq 3 ]]; then
    process_batch "$batch_index" "$batch_tmp"
    : > "$batch_tmp"
    batch_count="0"
    batch_index="$((batch_index + 1))"
    generated_any="1"
  fi
done < "$changed_files_txt"

if [[ "$batch_count" -gt 0 ]]; then
  process_batch "$batch_index" "$batch_tmp"
  generated_any="1"
fi
rm -f "$batch_tmp"

[[ "$generated_any" == "1" ]] || die "reviewer 対象ファイルがありません"

aggregate_path="$target_round_dir/reviewer_aggregate.json"
if [[ "$dry_run" == "1" ]]; then
  echo "[dry-run] aggregate target: $aggregate_path"
  printf '%s\n' "$aggregate_path"
  exit 0
fi

batch_outputs=("$target_round_dir"/reviewer_batch_*.json)
[[ -e "${batch_outputs[0]}" ]] || die "reviewer の出力が見つかりません"

jq -s '
  def rank:
    if . == "S" then 0
    elif . == "A" then 1
    elif . == "B" then 2
    else 3 end;
  . as $reviews
  | {
      overall_grade: ($reviews | max_by(.overall_grade | rank) | .overall_grade),
      critical_count: ($reviews | map(.critical_count) | add),
      approved: ($reviews | all(((.overall_grade == "S") or (.overall_grade == "A")) and (.critical_count == 0) and (.next_action == "approved"))),
      findings: ($reviews | map(.findings) | add),
      good_points: ($reviews | map(.good_points) | add | unique),
      next_action: (
        if ($reviews | all(((.overall_grade == "S") or (.overall_grade == "A")) and (.critical_count == 0) and (.next_action == "approved")))
        then "done"
        else "fix_and_rerun"
        end
      )
    }' "${batch_outputs[@]}" > "$aggregate_path"

aggregate_grade="$(jq -r '.overall_grade' "$aggregate_path")"
aggregate_critical="$(jq -r '.critical_count' "$aggregate_path")"
state_tmp="$(mktemp)"
jq \
  --arg updated_at "$(timestamp)" \
  --arg aggregate_grade "$aggregate_grade" \
  --argjson aggregate_critical "$aggregate_critical" \
  '.status = "judging"
   | .last_reviewer_grade = $aggregate_grade
   | .last_critical_count = $aggregate_critical
   | .updated_at = $updated_at' \
  "$(state_file "$job_name")" > "$state_tmp"
mv "$state_tmp" "$(state_file "$job_name")"

append_event "$job_name" "run-reviewer" "round $round_number reviewer finished"
printf '%s\n' "$aggregate_path"
