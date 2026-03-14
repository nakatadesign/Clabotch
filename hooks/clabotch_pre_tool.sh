#!/usr/bin/env bash
# PreToolUse: session_start（初回のみ）+ tool_start を送る
source "$(dirname "$0")/clabotch_lib.sh"

# ① stdin を必ず読む（EPIPE 防止）
HOOK_JSON=$(read_stdin)
SESSION_ID=$(resolve_session_id "$HOOK_JSON")

# session_id が取れなければ drop-and-log（exit 1 = 非ブロッキングエラー）
# "unknown" を合成しないことで SESSION_REGISTRY への汚染を防ぐ
if [[ -z "$SESSION_ID" ]]; then
  echo "[clabotch] WARN: session_id missing in PreToolUse payload, dropping event" >&2
  exit 1
fi

# session_id の文字種バリデーション（パストラバーサル・JSON インジェクション防止）
if ! validate_session_id "$SESSION_ID"; then
  exit 1
fi

# TOOL_QUOTED: surrounding " 込みの JSON 文字列  例) "Bash"
TOOL_QUOTED=$(json_escape "$(resolve_tool_name "$HOOK_JSON")")
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ② session_start（初回のみ）+ tool_start を1接続で送信（順序保証）
# session_start と tool_start が別接続だと受信側で順序逆転する可能性がある。
# 1つの nc 接続に NDJSON で連結して送ることで、接続内の serial queue で順序を保証する。
SESSION_START_FILE="${SESSION_REGISTRY}/${SESSION_ID}"
mkdir -p "$SESSION_REGISTRY"

# session_start が必要かどうかパイプ前に判定（パイプ内はサブシェルなので変数が伝播しない）
INCLUDES_SESSION_START=false
[[ ! -f "$SESSION_START_FILE" ]] && INCLUDES_SESSION_START=true

# NDJSON ペイロードを構築して1接続で送信
# 注意: $() は末尾改行を除去するため使わない。直接パイプで printf → send_json。
{
  if [[ "$INCLUDES_SESSION_START" == "true" ]]; then
    printf '{"schema_version":"1","event":"session_start","session_id":"%s","event_id":"%s","timestamp":"%s"}\n' \
      "$SESSION_ID" "$(generate_uuid)" "$NOW"
  fi
  printf '{"schema_version":"1","event":"tool_start","session_id":"%s","event_id":"%s","timestamp":"%s","tool_name":%s}\n' \
    "$SESSION_ID" "$(generate_uuid)" "$NOW" "$TOOL_QUOTED"
} | send_json
SEND_RC=$?
if [[ "$SEND_RC" -eq 0 && "$INCLUDES_SESSION_START" == "true" ]]; then
  date +%s > "$SESSION_START_FILE"
fi
