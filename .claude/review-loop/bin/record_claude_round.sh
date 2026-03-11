#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"
require_cmd jq

job_name=""
summary_file=""
quality_analyze=""
quality_test=""
quality_notes=""
force="0"
changed_files=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --job-name)
      job_name="${2:-}"
      shift 2
      ;;
    --summary-file)
      summary_file="${2:-}"
      shift 2
      ;;
    --changed-file)
      changed_files+=("${2:-}")
      shift 2
      ;;
    --quality-analyze)
      quality_analyze="${2:-}"
      shift 2
      ;;
    --quality-test)
      quality_test="${2:-}"
      shift 2
      ;;
    --quality-notes)
      quality_notes="${2:-}"
      shift 2
      ;;
    --force)
      force="1"
      shift
      ;;
    *)
      die "未対応の引数です: $1"
      ;;
  esac
done

[[ -n "$job_name" ]] || die "--job-name を指定してください"
[[ -n "$summary_file" ]] || die "--summary-file を指定してください"
[[ -f "$summary_file" ]] || die "summary file が見つかりません: $summary_file"
[[ -n "$quality_analyze" ]] || die "--quality-analyze を指定してください"
[[ -n "$quality_test" ]] || die "--quality-test を指定してください"
[[ "${#changed_files[@]}" -gt 0 ]] || die "--changed-file を 1 件以上指定してください"

ensure_job_exists "$job_name"
status_value="$(current_status "$job_name")"
current="$(current_round "$job_name")"
max_rounds="$(jq -r '.max_rounds' "$(state_file "$job_name")")"

if [[ "$force" == "1" && ("$status_value" == "reviewing" || "$status_value" == "judging") ]]; then
  next_round="$current"
else
  if [[ "$status_value" == "reviewing" || "$status_value" == "judging" ]]; then
    die "現在ラウンドはレビュー中です。上書きするなら --force を指定してください"
  fi
  next_round="$((current + 1))"
  if [[ "$next_round" -gt "$max_rounds" ]]; then
    die "max_rounds ($max_rounds) に達しました。これ以上ラウンドを追加できません"
  fi
fi

target_round_dir="$(round_dir "$job_name" "$next_round")"

if [[ "$force" == "1" && -d "$target_round_dir" ]]; then
  rm -f "$target_round_dir"/reviewer_batch_*.json \
        "$target_round_dir"/reviewer_batch_*.prompt.md \
        "$target_round_dir"/reviewer_batch_*.stdout.log \
        "$target_round_dir"/reviewer_batch_*.stderr.log \
        "$target_round_dir/reviewer_aggregate.json" \
        "$target_round_dir/judge.json" \
        "$target_round_dir/judge.prompt.md" \
        "$target_round_dir/judge.stdout.log" \
        "$target_round_dir/judge.stderr.log"
fi
mkdir -p "$target_round_dir"

cp "$summary_file" "$target_round_dir/claude_summary.md"

changed_tmp="$(mktemp)"
for path in "${changed_files[@]}"; do
  normalize_path "$path"
done | awk 'NF && !seen[$0]++' > "$changed_tmp"

[[ -s "$changed_tmp" ]] || die "changed_files が空です"
cp "$changed_tmp" "$target_round_dir/changed_files.txt"
changed_files_json="$(jq -Rsc 'split("\n") | map(select(length > 0))' < "$changed_tmp")"
rm -f "$changed_tmp"

jq -n \
  --arg summary_md "$(cat "$target_round_dir/claude_summary.md")" \
  --arg analyze "$quality_analyze" \
  --arg test "$quality_test" \
  --arg notes "$quality_notes" \
  --arg recorded_at "$(timestamp)" \
  --argjson round "$next_round" \
  --argjson changed_files "$changed_files_json" \
  '{
    round: $round,
    recorded_at: $recorded_at,
    summary_md: $summary_md,
    changed_files: $changed_files,
    quality_gate: {
      analyze: $analyze,
      test: $test,
      notes: $notes
    }
  }' > "$target_round_dir/claude_summary.json"

state_tmp="$(mktemp)"
jq \
  --arg updated_at "$(timestamp)" \
  --argjson current_round "$next_round" \
  '.current_round = $current_round
   | .status = "reviewing"
   | .manager_spot_check = null
   | .updated_at = $updated_at' \
  "$(state_file "$job_name")" > "$state_tmp"
mv "$state_tmp" "$(state_file "$job_name")"

append_event "$job_name" "record-claude" "round $next_round recorded"
printf '%s\n' "$target_round_dir"
