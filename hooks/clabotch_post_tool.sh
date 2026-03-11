#!/usr/bin/env bash
# PostToolUse: 成功時のみ発火。is_error=false 固定。
# duration は $CLAUDE_TOOL_DURATION（ms）で取得。
source "$(dirname "$0")/clabotch_lib.sh"

# ① stdin を必ず読む
HOOK_JSON=$(read_stdin)
SESSION_ID=$(resolve_session_id "$HOOK_JSON")

if [[ -z "$SESSION_ID" ]]; then
  echo "[clabotch] WARN: session_id missing in PostToolUse payload, dropping event" >&2
  exit 1
fi

if ! validate_session_id "$SESSION_ID"; then
  exit 1
fi

TOOL_QUOTED=$(json_escape "$(resolve_tool_name "$HOOK_JSON")")
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ② tool_name は %s（json_escape が " を含む）
printf '{"schema_version":"1","event":"tool_end","session_id":"%s","event_id":"%s","timestamp":"%s","tool_name":%s,"duration_ms":%s,"is_error":false,"error_message":null}\n' \
  "$SESSION_ID" "$(generate_uuid)" "$NOW" "$TOOL_QUOTED" \
  "${CLAUDE_TOOL_DURATION:-0}" | send_json || true
