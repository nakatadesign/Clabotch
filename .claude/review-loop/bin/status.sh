#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"
require_cmd jq

job_name=""
as_json="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --job-name)
      job_name="${2:-}"
      shift 2
      ;;
    --json)
      as_json="1"
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
target_round_dir="$(round_dir "$job_name" "$round_number")"
aggregate_path="$target_round_dir/reviewer_aggregate.json"
judge_path="$target_round_dir/judge.json"

if [[ "$as_json" == "1" ]]; then
  reviewer_json="null"
  judge_json="null"
  if [[ -f "$aggregate_path" ]]; then
    reviewer_json="$(cat "$aggregate_path")"
  fi
  if [[ -f "$judge_path" ]]; then
    judge_json="$(cat "$judge_path")"
  fi

  jq \
    --argjson reviewer_aggregate "$reviewer_json" \
    --argjson judge "$judge_json" \
    '. + {
      reviewer_aggregate: $reviewer_aggregate,
      judge: $judge
    }' "$(state_file "$job_name")"
  exit 0
fi

echo "job: $job_name"
echo "status: $(jq -r '.status' "$(state_file "$job_name")")"
echo "round: $(jq -r '.current_round' "$(state_file "$job_name")")/$(jq -r '.max_rounds' "$(state_file "$job_name")")"
echo "last_decision: $(jq -r '.last_decision // "null"' "$(state_file "$job_name")")"
echo "last_reviewer_grade: $(jq -r '.last_reviewer_grade // "null"' "$(state_file "$job_name")")"
echo "last_critical_count: $(jq -r '.last_critical_count' "$(state_file "$job_name")")"
echo "updated_at: $(jq -r '.updated_at' "$(state_file "$job_name")")"

if [[ -f "$judge_path" ]]; then
  echo "judge_decision: $(jq -r '.decision' "$judge_path")"
  echo "judge_reason: $(jq -r '.reason' "$judge_path")"
fi
