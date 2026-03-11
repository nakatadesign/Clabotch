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
[[ "$round_number" -gt 0 ]] || die "先に reviewer を実行してください"

target_round_dir="$(round_dir "$job_name" "$round_number")"
aggregate_path="$target_round_dir/reviewer_aggregate.json"
summary_md="$target_round_dir/claude_summary.md"
supervisor_spec="$REPO_ROOT/.claude/review-loop/SUPERVISOR.md"
[[ -f "$summary_md" ]] || die "claude_summary.md が見つかりません"
[[ -f "$supervisor_spec" ]] || die "SUPERVISOR.md が見つかりません"

if [[ ! -f "$aggregate_path" && "$dry_run" != "1" ]]; then
  die "reviewer_aggregate.json が見つかりません"
fi

state_summary="$(jq '{
  status,
  current_round,
  max_rounds,
  last_decision,
  last_reviewer_grade,
  last_critical_count
}' "$(state_file "$job_name")")"

prompt="$(cat <<EOF
あなたは review-loop の judge 役です。

以下の supervisor spec に従ってください:
$(cat "$supervisor_spec")

役割:
- reviewer の結果と進捗を読んで、次に進めるかを判定する
- コードの詳細レビューを一からやり直すのではなく、手元の要約情報から進行判断をする

ユーザー要求:
$(cat "$(goal_file "$job_name")")

job:
$job_name

現在の state:
$state_summary

Claude の今回ラウンド要約:
$(cat "$summary_md")

reviewer 集約結果:
$(if [[ -f "$aggregate_path" ]]; then cat "$aggregate_path"; else printf '%s\n' '{"note":"dry-run placeholder: reviewer aggregate not generated yet"}'; fi)

判定ルール:
- \`done\`: 要求を満たしており、重大指摘がなく、これ以上の修正を要求しない
- \`fix\`: まだ修正が必要
- \`continue\`: 修正ではなく追加確認や追加レビューを優先すべき
- \`human\`: 要件不明、優先順位競合、または人手判断が必要

出力ルール:
- JSON のみを返す
- Markdown コードフェンスは使わない
- \`must_fix\` は今ラウンドで優先して直すべき点
- \`can_defer\` は後回し可能な点
- findings の再レビューではなく、今回の進行判断に必要な要約にとどめる
EOF
)"

prompt_path="$target_round_dir/judge.prompt.md"
output_path="$target_round_dir/judge.json"
stdout_log="$target_round_dir/judge.stdout.log"
stderr_log="$target_round_dir/judge.stderr.log"
printf '%s\n' "$prompt" > "$prompt_path"

command=(codex -a never --sandbox read-only)
if [[ -n "$codex_model" ]]; then
  command+=(-m "$codex_model")
fi
command+=(exec -C "$REPO_ROOT" --output-schema "$SCHEMAS_DIR/judge.schema.json" -o "$output_path" -)

if [[ "$dry_run" == "1" ]]; then
  echo "[dry-run] judge prompt: $prompt_path"
  printf '%s\n' "${command[*]}"
  printf '%s\n' "$output_path"
  exit 0
fi

if ! printf '%s' "$prompt" | "${command[@]}" > "$stdout_log" 2> "$stderr_log"; then
  die "judge に失敗しました: $stderr_log"
fi

decision="$(jq -r '.decision' "$output_path")"
next_status="human"
case "$decision" in
  done) next_status="done" ;;
  fix) next_status="fix_requested" ;;
  continue) next_status="continue_requested" ;;
  human) next_status="human" ;;
  *) die "judge decision が不正です: $decision" ;;
esac

state_tmp="$(mktemp)"
jq \
  --arg updated_at "$(timestamp)" \
  --arg decision "$decision" \
  --arg next_status "$next_status" \
  '.last_decision = $decision
   | .status = $next_status
   | .updated_at = $updated_at' \
  "$(state_file "$job_name")" > "$state_tmp"
mv "$state_tmp" "$(state_file "$job_name")"

append_event "$job_name" "run-judge" "round $round_number judge returned $decision"
printf '%s\n' "$output_path"
