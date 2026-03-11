#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
BASE_DIR="$REPO_ROOT/.claude/review-loop"
RUNTIME_DIR="$BASE_DIR/runtime"
GOALS_DIR="$BASE_DIR/goals"
SCHEMAS_DIR="$BASE_DIR/schemas"

die() {
  echo "[review-loop] $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 が見つかりません"
}

timestamp() {
  date +"%Y-%m-%dT%H:%M:%S%z"
}

canonical_existing_path() {
  local path="$1"

  if command -v realpath >/dev/null 2>&1; then
    realpath "$path"
    return 0
  fi

  require_cmd perl
  perl -MCwd=realpath -e '
    my $path = shift @ARGV;
    my $resolved = realpath($path);
    defined $resolved or exit 1;
    print "$resolved\n";
  ' "$path" || die "path を解決できません: $path"
}

assert_path_within() {
  local root_path="$1"
  local candidate_path="$2"

  [[ "$candidate_path" == "$root_path" || "$candidate_path" == "$root_path"/* ]] \
    || die "path が許可されたディレクトリ外です: $candidate_path"
}

ensure_runtime_root() {
  mkdir -p "$BASE_DIR"
  mkdir -p "$RUNTIME_DIR"

  [[ ! -L "$RUNTIME_DIR" ]] || die "runtime ディレクトリに symlink は使えません: $RUNTIME_DIR"

  local real_base_dir real_runtime_dir
  real_base_dir="$(canonical_existing_path "$BASE_DIR")"
  real_runtime_dir="$(canonical_existing_path "$RUNTIME_DIR")"
  assert_path_within "$real_base_dir" "$real_runtime_dir"
}

job_dir() {
  printf '%s\n' "$RUNTIME_DIR/$1"
}

job_dir_realpath() {
  canonical_existing_path "$(job_dir "$1")"
}

state_file() {
  printf '%s/state.json\n' "$(job_dir "$1")"
}

goal_file() {
  printf '%s/goal.md\n' "$(job_dir "$1")"
}

events_file() {
  printf '%s/events.jsonl\n' "$(job_dir "$1")"
}

round_dir() {
  local job_name="$1"
  local round_number="$2"
  printf '%s/rounds/%03d\n' "$(job_dir "$job_name")" "$round_number"
}

validate_job_name() {
  local name="$1"
  if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
    die "job_name は英数字・ハイフン・アンダースコア・ドットのみ使用可能です（先頭は英数字）: $name"
  fi
  if [[ "$name" == *..* || "$name" == *.* && ${#name} -le 2 ]]; then
    die "job_name にパストラバーサルを含めることはできません: $name"
  fi
}

ensure_job_exists() {
  validate_job_name "$1"
  ensure_runtime_root

  local target_dir real_runtime_dir real_job_dir
  target_dir="$(job_dir "$1")"

  [[ -e "$target_dir" ]] || die "job が見つかりません: $1"
  [[ ! -L "$target_dir" ]] || die "job ディレクトリに symlink は使えません: $target_dir"
  [[ -f "$(state_file "$1")" ]] || die "state.json が見つかりません: $1"

  real_runtime_dir="$(canonical_existing_path "$RUNTIME_DIR")"
  real_job_dir="$(job_dir_realpath "$1")"
  assert_path_within "$real_runtime_dir" "$real_job_dir"
}

assert_safe_job_reset_target() {
  local job_name="$1"
  local target_dir real_runtime_dir real_target_dir

  validate_job_name "$job_name"
  ensure_runtime_root
  target_dir="$(job_dir "$job_name")"

  if [[ -L "$target_dir" ]]; then
    die "job ディレクトリに symlink は使えません: $target_dir"
  fi

  if [[ -e "$target_dir" ]]; then
    real_runtime_dir="$(canonical_existing_path "$RUNTIME_DIR")"
    real_target_dir="$(canonical_existing_path "$target_dir")"
    assert_path_within "$real_runtime_dir" "$real_target_dir"
  fi
}

normalize_path() {
  local raw_path="$1"
  case "$raw_path" in
    "$REPO_ROOT"/*) printf '%s\n' "${raw_path#$REPO_ROOT/}" ;;
    *) printf '%s\n' "$raw_path" ;;
  esac
}

append_event() {
  local job_name="$1"
  local kind="$2"
  local detail="$3"
  jq -nc \
    --arg ts "$(timestamp)" \
    --arg kind "$kind" \
    --arg detail "$detail" \
    '{timestamp:$ts, kind:$kind, detail:$detail}' >> "$(events_file "$job_name")"
}

current_round() {
  jq -r '.current_round' "$(state_file "$1")"
}

current_status() {
  jq -r '.status' "$(state_file "$1")"
}
