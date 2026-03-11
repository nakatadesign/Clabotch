#!/usr/bin/env bash
# PostToolUseFailure: ツール失敗時のみ発火。is_error=true を送る。
source "$(dirname "$0")/clabotch_lib.sh"

# ① stdin を必ず読む
HOOK_JSON=$(read_stdin)
SESSION_ID=$(resolve_session_id "$HOOK_JSON")

if [[ -z "$SESSION_ID" ]]; then
  echo "[clabotch] WARN: session_id missing in PostToolUseFailure payload, dropping event" >&2
  exit 1
fi

if ! validate_session_id "$SESSION_ID"; then
  exit 1
fi

TOOL_QUOTED=$(json_escape "$(resolve_tool_name "$HOOK_JSON")")
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

printf '{"schema_version":"1","event":"tool_end","session_id":"%s","event_id":"%s","timestamp":"%s","tool_name":%s,"duration_ms":%s,"is_error":true,"error_message":"tool failed"}\n' \
  "$SESSION_ID" "$(generate_uuid)" "$NOW" "$TOOL_QUOTED" \
  "${CLAUDE_TOOL_DURATION:-0}" | send_json || true
