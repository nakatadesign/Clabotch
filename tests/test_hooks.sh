#!/usr/bin/env bash
# Clabotch Hook 疎通テスト
# 使い方: bash tests/test_hooks.sh
# set -e は使わない（テスト内で exit 1 を期待するため）
set -uo pipefail

HOOKS_DIR="$(cd "$(dirname "$0")/../hooks" && pwd)"
PASS=0
FAIL=0
TOTAL=0

assert_exit() {
  local name="$1" exit_code="$2" expected="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$exit_code" -eq "$expected" ]]; then
    echo "  PASS: $name (exit=$exit_code)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name (exit=$exit_code, expected=$expected)"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local name="$1" output="$2" pattern="$3"
  TOTAL=$((TOTAL + 1))
  if echo "$output" | grep -q "$pattern"; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name (pattern '$pattern' not found in output)"
    FAIL=$((FAIL + 1))
  fi
}

# テスト用一時ディレクトリ
export TMPDIR="${TMPDIR:-/tmp/}"
TEST_REGISTRY="${TMPDIR}clabotch_sessions_test_$$"
rm -rf "$TEST_REGISTRY"
trap 'rm -rf "$TEST_REGISTRY"' EXIT

VALID_JSON='{"session_id":"test-session-001","tool_name":"Read"}'
NO_SID_JSON='{"tool_name":"Bash"}'

echo "=== Clabotch Hook 疎通テスト ==="
echo ""

# ────────────────────────────────────────────────────────────────────────
echo "[1] jq 存在確認"
TOTAL=$((TOTAL + 1))
if command -v jq &>/dev/null; then
  echo "  PASS: jq が利用可能 ($(which jq))"
  PASS=$((PASS + 1))
else
  echo "  FAIL: jq が見つからない（brew install jq が必要）"
  FAIL=$((FAIL + 1))
  echo "jq がないためテスト中断。"
  exit 1
fi

# ────────────────────────────────────────────────────────────────────────
echo ""
echo "[2] session_id 欠損時の drop-and-log テスト"

for script in clabotch_pre_tool.sh clabotch_post_tool.sh clabotch_post_tool_failure.sh clabotch_stop.sh; do
  OUTPUT=$(echo "$NO_SID_JSON" | bash "$HOOKS_DIR/$script" 2>&1) || EC=$?
  EC=${EC:-0}
  assert_exit "$script: session_id 欠損 → exit 1" "$EC" 1
  assert_contains "$script: drop-and-log メッセージ" "$OUTPUT" "session_id missing"
  unset EC
done

# ────────────────────────────────────────────────────────────────────────
echo ""
echo "[3] 正常 JSON でスクリプトが落ちないこと（socket 不在）"

for script in clabotch_pre_tool.sh clabotch_post_tool.sh clabotch_post_tool_failure.sh clabotch_stop.sh; do
  echo "$VALID_JSON" | bash "$HOOKS_DIR/$script" >/dev/null 2>&1 || EC=$?
  EC=${EC:-0}
  assert_exit "$script: 正常 JSON → exit 0" "$EC" 0
  unset EC
done

# ────────────────────────────────────────────────────────────────────────
echo ""
echo "[4] socket 不在時のハング確認（各スクリプト3秒以内に完了）"

for script in clabotch_pre_tool.sh clabotch_post_tool.sh clabotch_post_tool_failure.sh clabotch_stop.sh; do
  START_T=$(date +%s)
  echo "$VALID_JSON" | bash "$HOOKS_DIR/$script" >/dev/null 2>&1 || true
  END_T=$(date +%s)
  ELAPSED=$((END_T - START_T))
  TOTAL=$((TOTAL + 1))
  if [[ "$ELAPSED" -lt 3 ]]; then
    echo "  PASS: $script: ${ELAPSED}秒で完了"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $script: ${ELAPSED}秒（タイムアウト）"
    FAIL=$((FAIL + 1))
  fi
done

# ────────────────────────────────────────────────────────────────────────
echo ""
echo "[5] clabotch_lib.sh 関数単体テスト"

# json_escape
ESCAPED=$(source "$HOOKS_DIR/clabotch_lib.sh" && json_escape 'hello "world"')
TOTAL=$((TOTAL + 1))
if [[ "$ESCAPED" == '"hello \"world\""' ]]; then
  echo "  PASS: json_escape"
  PASS=$((PASS + 1))
else
  echo "  FAIL: json_escape result='$ESCAPED'"
  FAIL=$((FAIL + 1))
fi

# resolve_session_id（正常）
SID=$(source "$HOOKS_DIR/clabotch_lib.sh" && resolve_session_id '{"session_id":"abc-123"}')
assert_contains "resolve_session_id 正常" "$SID" "abc-123"

# resolve_session_id（欠損 → 空文字列）
SID=$(source "$HOOKS_DIR/clabotch_lib.sh" && resolve_session_id '{"tool_name":"Bash"}')
TOTAL=$((TOTAL + 1))
if [[ -z "$SID" ]]; then
  echo "  PASS: resolve_session_id 欠損 → 空文字列"
  PASS=$((PASS + 1))
else
  echo "  FAIL: resolve_session_id 欠損で '$SID' が返った"
  FAIL=$((FAIL + 1))
fi

# resolve_session_id（CLAUDE_SESSION_ID 環境変数 fallback）
SID=$(CLAUDE_SESSION_ID="env-fb-id" bash -c 'source "'"$HOOKS_DIR"'/clabotch_lib.sh" && resolve_session_id "{}"')
assert_contains "resolve_session_id 環境変数 fallback" "$SID" "env-fb-id"

# resolve_tool_name
TNAME=$(source "$HOOKS_DIR/clabotch_lib.sh" && resolve_tool_name '{"tool_name":"Write"}')
assert_contains "resolve_tool_name 正常" "$TNAME" "Write"

# resolve_tool_name（欠損 → "unknown"）
TNAME=$(source "$HOOKS_DIR/clabotch_lib.sh" && resolve_tool_name '{}')
assert_contains "resolve_tool_name 欠損 → unknown" "$TNAME" "unknown"

# ────────────────────────────────────────────────────────────────────────
echo ""
echo "[6] pre_tool session_start ファイル作成テスト（socket 不在時は marker を作らない）"

# clabotch_lib.sh が SESSION_REGISTRY を固定値で定義するため、デフォルトの場所を使う
DEFAULT_REGISTRY="${TMPDIR%/}/clabotch_sessions"
TEST_SID="test-hook-$$-$(date +%s)"

echo "{\"session_id\":\"$TEST_SID\",\"tool_name\":\"Bash\"}" | \
  bash "$HOOKS_DIR/clabotch_pre_tool.sh" >/dev/null 2>&1 || true
TOTAL=$((TOTAL + 1))
# socket 不在のため marker は作成されないのが正しい動作
if [[ ! -f "$DEFAULT_REGISTRY/$TEST_SID" ]]; then
  echo "  PASS: socket 不在時に marker が作成されない（正常動作）"
  PASS=$((PASS + 1))
else
  echo "  FAIL: socket 不在なのに marker が作成された"
  rm -f "$DEFAULT_REGISTRY/$TEST_SID"
  FAIL=$((FAIL + 1))
fi

# ────────────────────────────────────────────────────────────────────────
echo ""
echo "[7] stop の session_start ファイル削除テスト"

# 先に session_start ファイルを作成（デフォルトの REGISTRY を使う）
TEST_STOP_SID="test-stop-$$-$(date +%s)"
mkdir -p "$DEFAULT_REGISTRY"
echo "$(date +%s)" > "$DEFAULT_REGISTRY/$TEST_STOP_SID"
echo "{\"session_id\":\"$TEST_STOP_SID\"}" | \
  bash "$HOOKS_DIR/clabotch_stop.sh" >/dev/null 2>&1 || true
TOTAL=$((TOTAL + 1))
if [[ ! -f "$DEFAULT_REGISTRY/$TEST_STOP_SID" ]]; then
  echo "  PASS: stop 後に session_start ファイルが削除された"
  PASS=$((PASS + 1))
else
  echo "  FAIL: session_start ファイルが残っている"
  rm -f "$DEFAULT_REGISTRY/$TEST_STOP_SID"
  FAIL=$((FAIL + 1))
fi

# ────────────────────────────────────────────────────────────────────────
echo ""
echo "[8] 不正な session_id のバリデーションテスト"

# 予約パス名 "." の拒否
OUTPUT=$(echo '{"session_id":".","tool_name":"Bash"}' | bash "$HOOKS_DIR/clabotch_pre_tool.sh" 2>&1) || EC=$?
EC=${EC:-0}
assert_exit "session_id '.' → exit 1" "$EC" 1
assert_contains "'.' 拒否メッセージ" "$OUTPUT" "reserved path name"
unset EC

# 予約パス名 ".." の拒否
OUTPUT=$(echo '{"session_id":"..","tool_name":"Bash"}' | bash "$HOOKS_DIR/clabotch_pre_tool.sh" 2>&1) || EC=$?
EC=${EC:-0}
assert_exit "session_id '..' → exit 1" "$EC" 1
assert_contains "'..' 拒否メッセージ" "$OUTPUT" "reserved path name"
unset EC

# パストラバーサル（../）
OUTPUT=$(echo '{"session_id":"../../../etc/passwd","tool_name":"Bash"}' | bash "$HOOKS_DIR/clabotch_pre_tool.sh" 2>&1) || EC=$?
EC=${EC:-0}
assert_exit "session_id '../../../etc/passwd' → exit 1" "$EC" 1
assert_contains "パストラバーサル検知メッセージ" "$OUTPUT" "unsafe characters"
unset EC

# JSON インジェクション（"）
OUTPUT=$(echo '{"session_id":"abc\"inject","tool_name":"Bash"}' | bash "$HOOKS_DIR/clabotch_pre_tool.sh" 2>&1) || EC=$?
EC=${EC:-0}
assert_exit "session_id にダブルクォート → exit 1" "$EC" 1
unset EC

# 改行を含む session_id
OUTPUT=$(printf '{"session_id":"abc\\ndef","tool_name":"Bash"}' | bash "$HOOKS_DIR/clabotch_pre_tool.sh" 2>&1) || EC=$?
EC=${EC:-0}
assert_exit "session_id に改行 → exit 1" "$EC" 1
unset EC

# スラッシュを含む session_id
OUTPUT=$(echo '{"session_id":"abc/def","tool_name":"Bash"}' | bash "$HOOKS_DIR/clabotch_pre_tool.sh" 2>&1) || EC=$?
EC=${EC:-0}
assert_exit "session_id にスラッシュ → exit 1" "$EC" 1
unset EC

# 正常な UUID 形式はパス
OUTPUT=$(echo '{"session_id":"550e8400-e29b-41d4-a716-446655440000","tool_name":"Bash"}' | bash "$HOOKS_DIR/clabotch_pre_tool.sh" 2>&1) || EC=$?
EC=${EC:-0}
assert_exit "UUID 形式の session_id → exit 0" "$EC" 0
rm -f "$DEFAULT_REGISTRY/550e8400-e29b-41d4-a716-446655440000"
unset EC

# post_tool / post_tool_failure / stop でもバリデーションが効くこと
for script in clabotch_post_tool.sh clabotch_post_tool_failure.sh clabotch_stop.sh; do
  OUTPUT=$(echo '{"session_id":"../evil","tool_name":"Bash"}' | bash "$HOOKS_DIR/$script" 2>&1) || EC=$?
  EC=${EC:-0}
  assert_exit "$script: 不正 session_id → exit 1" "$EC" 1
  unset EC
done

# ────────────────────────────────────────────────────────────────────────
echo ""
echo "[9] 壊れた stdin JSON のテスト"

# 完全に壊れた JSON
OUTPUT=$(echo 'this is not json at all' | bash "$HOOKS_DIR/clabotch_pre_tool.sh" 2>&1) || EC=$?
EC=${EC:-0}
assert_exit "壊れた JSON → exit 1（session_id 取得不可）" "$EC" 1
unset EC

# 空の stdin
OUTPUT=$(echo '' | bash "$HOOKS_DIR/clabotch_pre_tool.sh" 2>&1) || EC=$?
EC=${EC:-0}
assert_exit "空 stdin → exit 1" "$EC" 1
unset EC

# 途中で切れた JSON
OUTPUT=$(echo '{"session_id":"abc' | bash "$HOOKS_DIR/clabotch_pre_tool.sh" 2>&1) || EC=$?
EC=${EC:-0}
assert_exit "不完全 JSON → exit 1" "$EC" 1
unset EC

# ────────────────────────────────────────────────────────────────────────
echo ""
echo "[10] socket 不在→復帰シナリオテスト"

# socket 不在の状態で pre_tool を実行 → marker が作られないことを確認
RECOVERY_SID="recovery-test-$$-$(date +%s)"
rm -f "$DEFAULT_REGISTRY/$RECOVERY_SID"

echo "{\"session_id\":\"$RECOVERY_SID\",\"tool_name\":\"Bash\"}" | \
  bash "$HOOKS_DIR/clabotch_pre_tool.sh" >/dev/null 2>&1 || true
TOTAL=$((TOTAL + 1))
if [[ ! -f "$DEFAULT_REGISTRY/$RECOVERY_SID" ]]; then
  echo "  PASS: socket 不在時に marker が作成されない"
  PASS=$((PASS + 1))
else
  echo "  FAIL: socket 不在なのに marker が作られた"
  rm -f "$DEFAULT_REGISTRY/$RECOVERY_SID"
  FAIL=$((FAIL + 1))
fi

# socket を模擬作成して、再度 pre_tool → 今度は marker が作られること
MOCK_SOCK="${TMPDIR%/}/clabotch.sock"
# socat で一時的なリスニングソケットを作成（バックグラウンド）
if command -v socat &>/dev/null; then
  socat UNIX-LISTEN:"$MOCK_SOCK",fork /dev/null &
  SOCAT_PID=$!
  # ソケットが作られるまで少し待つ
  for i in 1 2 3 4 5; do
    [[ -S "$MOCK_SOCK" ]] && break
    sleep 0.1
  done

  echo "{\"session_id\":\"$RECOVERY_SID\",\"tool_name\":\"Bash\"}" | \
    bash "$HOOKS_DIR/clabotch_pre_tool.sh" >/dev/null 2>&1 || true
  TOTAL=$((TOTAL + 1))
  if [[ -f "$DEFAULT_REGISTRY/$RECOVERY_SID" ]]; then
    echo "  PASS: socket 復帰後に marker が作成された（session_start 再送成功）"
    PASS=$((PASS + 1))
    rm -f "$DEFAULT_REGISTRY/$RECOVERY_SID"
  else
    echo "  FAIL: socket 復帰後に marker が作成されない"
    FAIL=$((FAIL + 1))
  fi

  kill "$SOCAT_PID" 2>/dev/null || true
  wait "$SOCAT_PID" 2>/dev/null || true
  rm -f "$MOCK_SOCK"
else
  echo "  SKIP: socat が未導入のため socket 復帰テストはスキップ"
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
fi

# ────────────────────────────────────────────────────────────────────────
echo ""
echo "=== テスト結果: $PASS/$TOTAL passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
