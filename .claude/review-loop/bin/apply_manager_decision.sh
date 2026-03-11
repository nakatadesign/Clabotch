#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"
require_cmd jq

job_name=""
decision=""
reason=""
from_judge=""
force="0"
spot_checked="0"
record_spot_check_only="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --job-name)
      job_name="${2:-}"
      shift 2
      ;;
    --decision)
      decision="${2:-}"
      shift 2
      ;;
    --reason)
      reason="${2:-}"
      shift 2
      ;;
    --from-judge)
      from_judge="${2:-}"
      shift 2
      ;;
    --force)
      force="1"
      shift
      ;;
    --spot-checked)
      spot_checked="1"
      shift
      ;;
    --record-spot-check)
      record_spot_check_only="1"
      shift
      ;;
    *)
      die "未対応の引数です: $1"
      ;;
  esac
done

[[ -n "$job_name" ]] || die "--job-name を指定してください"

# --record-spot-check モード: spot_check を state.json に記録して終了
if [[ "$record_spot_check_only" == "1" ]]; then
  ensure_job_exists "$job_name"

  round_number="$(current_round "$job_name")"
  [[ "$round_number" -gt 0 ]] || die "まだラウンドが開始されていません"
  target_round_dir="$(round_dir "$job_name" "$round_number")"

  judge_path="$target_round_dir/judge.json"
  [[ -f "$judge_path" ]] || die "judge.json が見つかりません"

  checked_files="$(jq '.must_fix // []' "$judge_path")"

  spot_check_record="$(jq -nc \
    --arg checked_at "$(timestamp)" \
    --argjson round "$round_number" \
    --argjson checked_files "$checked_files" \
    '{checked_at: $checked_at, round: $round, checked_files: $checked_files}')"

  state_tmp="$(mktemp)"
  jq \
    --arg updated_at "$(timestamp)" \
    --argjson manager_spot_check "$spot_check_record" \
    '.manager_spot_check = $manager_spot_check
     | .updated_at = $updated_at' \
    "$(state_file "$job_name")" > "$state_tmp"
  mv "$state_tmp" "$(state_file "$job_name")"

  append_event "$job_name" "manager-spot-check" "round $round_number spot check recorded: $(printf '%s' "$checked_files" | jq -c .)"
  echo "[review-loop] spot check recorded."
  exit 0
fi

[[ -n "$decision" ]] || die "--decision を指定してください"
ensure_job_exists "$job_name"

# status が manager_review であることを検証（--force で回避可能）
current="$(current_status "$job_name")"
if [[ "$force" != "1" && "$current" != "manager_review" ]]; then
  die "status が manager_review ではありません: ${current} (--force で強制実行可能)"
fi

case "$decision" in
  fix|continue|done|human) ;;
  *) die "--decision は fix / continue / done / human のいずれかです: $decision" ;;
esac

round_number="$(current_round "$job_name")"
[[ "$round_number" -gt 0 ]] || die "まだラウンドが開始されていません"

target_round_dir="$(round_dir "$job_name" "$round_number")"

# judge.json のパスを決定
if [[ -n "$from_judge" ]]; then
  [[ -f "$from_judge" ]] || die "judge.json が見つかりません: $from_judge"
  real_judge_path="$(canonical_existing_path "$from_judge")"
  real_round_dir="$(canonical_existing_path "$target_round_dir")"
  assert_path_within "$real_round_dir" "$real_judge_path"
  judge_path="$from_judge"
else
  judge_path="$target_round_dir/judge.json"
fi
[[ -f "$judge_path" ]] || die "judge.json が見つかりません: $judge_path"

judge_recommendation="$(jq -r '.recommendation' "$judge_path")"

# done の場合は4条件を検証
if [[ "$decision" == "done" ]]; then
  aggregate_path="$target_round_dir/reviewer_aggregate.json"
  summary_json="$target_round_dir/claude_summary.json"

  gate_failures=()

  # 条件1: critical_count == 0
  if [[ -f "$aggregate_path" ]]; then
    aggregate_critical_count="$(jq -r '.critical_count // 0' "$aggregate_path")"
    if [[ "$aggregate_critical_count" != "0" ]]; then
      gate_failures+=("critical_count が 0 ではありません: $aggregate_critical_count")
    fi
  else
    gate_failures+=("reviewer_aggregate.json が見つかりません")
  fi

  # 条件2: quality_gate の analyze と test
  if [[ -f "$summary_json" ]]; then
    analyze_status="$(jq -r '.quality_gate.analyze // ""' "$summary_json")"
    test_status="$(jq -r '.quality_gate.test // ""' "$summary_json")"
    case "$analyze_status" in
      passed|skipped) ;;
      *) gate_failures+=("quality_gate.analyze が passed/skipped ではありません: $analyze_status") ;;
    esac
    case "$test_status" in
      passed|skipped) ;;
      *) gate_failures+=("quality_gate.test が passed/skipped ではありません: $test_status") ;;
    esac
  else
    gate_failures+=("claude_summary.json が見つかりません")
  fi

  # 条件3: judge recommendation == done
  if [[ "$judge_recommendation" != "done" ]]; then
    gate_failures+=("judge recommendation が done ではありません: $judge_recommendation")
  fi

  # 条件4: manager_spot_check が state.json に事前記録されていること
  existing_spot_check="$(jq -r '.manager_spot_check // null' "$(state_file "$job_name")")"
  if [[ "$existing_spot_check" == "null" ]]; then
    gate_failures+=("manager_spot_check が state.json に記録されていません。先に --record-spot-check を実行してください")
  fi

  # 条件4b: manager_spot_check の round が current round と一致すること
  if [[ "$existing_spot_check" != "null" ]]; then
    spot_check_round="$(printf '%s' "$existing_spot_check" | jq -r '.round // empty')"
    if [[ "$spot_check_round" != "$round_number" ]]; then
      gate_failures+=("manager_spot_check の round ($spot_check_round) が current round ($round_number) と一致しません。再度 --record-spot-check を実行してください")
    fi
  fi

  if [[ "${#gate_failures[@]}" -gt 0 ]]; then
    gate_failure_text="$(printf '%s; ' "${gate_failures[@]}")"
    gate_failure_text="${gate_failure_text%; }"
    echo "[review-loop] done 条件を満たしていません。human に変更します: $gate_failure_text" >&2
    decision="human"
    reason="done 条件未達: $gate_failure_text"
  fi
fi

# state.json を更新
next_status=""
case "$decision" in
  done) next_status="done" ;;
  fix) next_status="fix_requested" ;;
  continue) next_status="continue_requested" ;;
  human) next_status="human" ;;
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

# events.jsonl に記録
if [[ -n "$reason" ]]; then
  append_event "$job_name" "manager-decision" "round $round_number manager decided $decision: $reason"
else
  append_event "$job_name" "manager-decision" "round $round_number manager decided $decision (judge recommended $judge_recommendation)"
fi

echo "[review-loop] Manager decision: $decision (status: $next_status)"
