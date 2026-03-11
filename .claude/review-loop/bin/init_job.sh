#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"
require_cmd jq

job_name=""
goal_template=""
goal_path=""
goal_text=""
max_rounds="3"
force="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --job-name)
      job_name="${2:-}"
      shift 2
      ;;
    --goal-template)
      goal_template="${2:-}"
      shift 2
      ;;
    --goal-file)
      goal_path="${2:-}"
      shift 2
      ;;
    --goal-text)
      goal_text="${2:-}"
      shift 2
      ;;
    --max-rounds)
      max_rounds="${2:-}"
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
validate_job_name "$job_name"
[[ "$max_rounds" =~ ^[1-9][0-9]*$ ]] || die "--max-rounds は 1 以上の整数で指定してください"

provided_count="0"
[[ -n "$goal_template" ]] && provided_count="$((provided_count + 1))"
[[ -n "$goal_path" ]] && provided_count="$((provided_count + 1))"
[[ -n "$goal_text" ]] && provided_count="$((provided_count + 1))"
[[ "$provided_count" -eq 1 ]] || die "--goal-template / --goal-file / --goal-text を 1 つだけ指定してください"

ensure_runtime_root
target_dir="$(job_dir "$job_name")"
if [[ -e "$target_dir" ]]; then
  [[ "$force" == "1" ]] || die "job は既に存在します: $target_dir"
  assert_safe_job_reset_target "$job_name"
  rm -rf "$target_dir"
fi

mkdir -p "$target_dir/rounds"

if [[ -n "$goal_template" ]]; then
  goal_source="$GOALS_DIR/$goal_template.md"
  [[ -f "$goal_source" ]] || die "goal template が見つかりません: $goal_template"
  cp "$goal_source" "$target_dir/goal.md"
elif [[ -n "$goal_path" ]]; then
  [[ -f "$goal_path" ]] || die "goal file が見つかりません: $goal_path"
  cp "$goal_path" "$target_dir/goal.md"
else
  printf '%s\n' "$goal_text" > "$target_dir/goal.md"
fi

jq -n \
  --arg job_name "$job_name" \
  --arg repo_root "$REPO_ROOT" \
  --arg created_at "$(timestamp)" \
  --arg updated_at "$(timestamp)" \
  --argjson max_rounds "$max_rounds" \
  '{
    job_name: $job_name,
    repo_root: $repo_root,
    created_at: $created_at,
    updated_at: $updated_at,
    current_round: 0,
    max_rounds: $max_rounds,
    status: "init",
    last_decision: null,
    last_reviewer_grade: null,
    last_critical_count: 0
  }' > "$target_dir/state.json"

: > "$target_dir/events.jsonl"
append_event "$job_name" "init" "job created"

printf '%s\n' "$target_dir"
