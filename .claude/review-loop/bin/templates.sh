#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

show_name=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --show)
      show_name="${2:-}"
      shift 2
      ;;
    *)
      die "未対応の引数です: $1"
      ;;
  esac
done

if [[ -n "$show_name" ]]; then
  template_path="$GOALS_DIR/$show_name.md"
  [[ -f "$template_path" ]] || die "template が見つかりません: $show_name"
  cat "$template_path"
  exit 0
fi

for path in "$GOALS_DIR"/*.md; do
  [[ -e "$path" ]] || exit 0
  basename "$path" .md
done
