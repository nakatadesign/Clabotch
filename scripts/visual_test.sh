#!/usr/bin/env bash
# scripts/visual_test.sh — Clabotch 視覚テスト
#
# 各フェーズを順番に送信し、間に十分な待機時間を挟む。
# 目視で表示を確認する。
#
# 使い方:
#   ./scripts/visual_test.sh              # 全フェーズを順番にテスト（各5秒）
#   ./scripts/visual_test.sh --interactive # 手動で Enter を押して進む
#   ./scripts/visual_test.sh --phase responding  # 特定フェーズだけテスト
set -euo pipefail

_TMPDIR="${TMPDIR%/}"
SOCK="${_TMPDIR}/clabotch/hook.sock"
SID="visual-test-$$"
WAIT=5
INTERACTIVE=false
SINGLE_PHASE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interactive|-i) INTERACTIVE=true; shift ;;
    --phase|-p) SINGLE_PHASE="$2"; shift 2 ;;
    --wait|-w) WAIT="$2"; shift 2 ;;
    --help|-h)
      echo "使い方: ./scripts/visual_test.sh [OPTIONS]"
      echo "  --interactive, -i    Enter で次に進む"
      echo "  --phase, -p PHASE    特定フェーズのみ (thinking/responding/working/error/done/idle)"
      echo "  --wait, -w SECONDS   各フェーズの待機秒数 (デフォルト: 5)"
      exit 0
      ;;
    *) echo "ERROR: 不明なオプション: $1" >&2; exit 1 ;;
  esac
done

send() {
  echo "$1" | nc -w 1 -U "$SOCK" 2>/dev/null
}

wait_or_enter() {
  if [[ "$INTERACTIVE" == "true" ]]; then
    echo "    → Enter で次へ..."
    read -r
  else
    echo "    → ${WAIT}秒待機..."
    sleep "$WAIT"
  fi
}

now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

uuid() {
  uuidgen | tr '[:upper:]' '[:lower:]'
}

# ソケット確認
if [[ ! -S "$SOCK" ]]; then
  echo "ERROR: ソケットが見つかりません: $SOCK" >&2
  echo "Clabotch.app が起動しているか確認してください" >&2
  exit 1
fi

echo "=== Clabotch 視覚テスト ==="
echo "ソケット: $SOCK"
echo "セッション: $SID"
echo ""

# --- フェーズ関数 ---

phase_thinking() {
  echo "[1] session_start → thinking（考えてます...）"
  send "{\"schema_version\":\"1\",\"event\":\"session_start\",\"session_id\":\"$SID\",\"event_id\":\"$(uuid)\",\"timestamp\":\"$(now)\"}"
  echo "    期待: 顔ピンクブラウン、視線が右上⇔左上交互、吹き出し「考えてます...」"
  echo "    ※ ずっと thinking のまま（返答中にはならない）"
  wait_or_enter
}

phase_working() {
  echo "[2] tool_start → working（作業中...）"
  send "{\"schema_version\":\"1\",\"event\":\"tool_start\",\"session_id\":\"$SID\",\"event_id\":\"$(uuid)\",\"timestamp\":\"$(now)\",\"tool_name\":\"Bash\"}"
  echo "    期待: 顔ゴールド、吹き出し「作業中... (Bash)」"
  wait_or_enter
}

phase_tool_end() {
  echo "[3] tool_end → thinking（0.8秒）→ responding"
  send "{\"schema_version\":\"1\",\"event\":\"tool_end\",\"session_id\":\"$SID\",\"event_id\":\"$(uuid)\",\"timestamp\":\"$(now)\",\"tool_name\":\"Bash\",\"duration_ms\":3000,\"is_error\":false,\"error_message\":null}"
  echo "    期待: 「考えてます...」が 0.8秒 → 「返答中...」に自動切替"
  echo "    → メニューバーを見て待ってください"
  echo "    → 切り替わりを確認したら Enter"
  wait_or_enter
}

phase_error() {
  echo "[4] tool_end(error) → error（エラーが出ました…）"
  send "{\"schema_version\":\"1\",\"event\":\"tool_start\",\"session_id\":\"$SID\",\"event_id\":\"$(uuid)\",\"timestamp\":\"$(now)\",\"tool_name\":\"Bash\"}"
  sleep 0.5
  send "{\"schema_version\":\"1\",\"event\":\"tool_end\",\"session_id\":\"$SID\",\"event_id\":\"$(uuid)\",\"timestamp\":\"$(now)\",\"tool_name\":\"Bash\",\"duration_ms\":500,\"is_error\":true,\"error_message\":\"コマンド失敗\"}"
  echo "    期待: 顔赤、×目、シェイク、吹き出し「エラーが出ました…」→ 2.5秒後 thinking に戻る"
  wait_or_enter
}

phase_done() {
  echo "[5] session_done → done（完了！）"
  send "{\"schema_version\":\"1\",\"event\":\"session_done\",\"session_id\":\"$SID\",\"event_id\":\"$(uuid)\",\"timestamp\":\"$(now)\",\"elapsed_ms\":42000}"
  echo "    期待: 顔ゴールド虹色、瞳スピン→ハッピー目、ジャンプ、吹き出し「完了！(42秒)」→ 4秒後 idle"
  wait_or_enter
}

phase_idle() {
  echo "[6] (セッション削除後) → idle"
  echo "    期待: 顔ピンクブラウン、吹き出しなし、通常目"
  wait_or_enter
}

# --- 実行 ---

if [[ -n "$SINGLE_PHASE" ]]; then
  case "$SINGLE_PHASE" in
    thinking)
      phase_thinking
      # クリーンアップ
      send "{\"schema_version\":\"1\",\"event\":\"session_done\",\"session_id\":\"$SID\",\"event_id\":\"$(uuid)\",\"timestamp\":\"$(now)\",\"elapsed_ms\":0}"
      ;;
    responding)
      send "{\"schema_version\":\"1\",\"event\":\"session_start\",\"session_id\":\"$SID\",\"event_id\":\"$(uuid)\",\"timestamp\":\"$(now)\"}"
      send "{\"schema_version\":\"1\",\"event\":\"tool_start\",\"session_id\":\"$SID\",\"event_id\":\"$(uuid)\",\"timestamp\":\"$(now)\",\"tool_name\":\"Bash\"}"
      sleep 0.3
      send "{\"schema_version\":\"1\",\"event\":\"tool_end\",\"session_id\":\"$SID\",\"event_id\":\"$(uuid)\",\"timestamp\":\"$(now)\",\"tool_name\":\"Bash\",\"duration_ms\":1000,\"is_error\":false,\"error_message\":null}"
      echo "tool_end 送信。0.8秒後に thinking → responding（「返答中...」）に自動切替"
      echo "    期待: 視線が中央⇔左下ゆっくり交互（2秒間隔）、吹き出し「返答中...」"
      wait_or_enter
      send "{\"schema_version\":\"1\",\"event\":\"session_done\",\"session_id\":\"$SID\",\"event_id\":\"$(uuid)\",\"timestamp\":\"$(now)\",\"elapsed_ms\":0}"
      ;;
    working)
      send "{\"schema_version\":\"1\",\"event\":\"session_start\",\"session_id\":\"$SID\",\"event_id\":\"$(uuid)\",\"timestamp\":\"$(now)\"}"
      phase_working
      send "{\"schema_version\":\"1\",\"event\":\"session_done\",\"session_id\":\"$SID\",\"event_id\":\"$(uuid)\",\"timestamp\":\"$(now)\",\"elapsed_ms\":0}"
      ;;
    error)
      send "{\"schema_version\":\"1\",\"event\":\"session_start\",\"session_id\":\"$SID\",\"event_id\":\"$(uuid)\",\"timestamp\":\"$(now)\"}"
      phase_error
      send "{\"schema_version\":\"1\",\"event\":\"session_done\",\"session_id\":\"$SID\",\"event_id\":\"$(uuid)\",\"timestamp\":\"$(now)\",\"elapsed_ms\":0}"
      ;;
    done)
      send "{\"schema_version\":\"1\",\"event\":\"session_start\",\"session_id\":\"$SID\",\"event_id\":\"$(uuid)\",\"timestamp\":\"$(now)\"}"
      phase_done
      ;;
    idle)
      echo "[idle] session_start → session_done → done(4秒) → idle"
      send "{\"schema_version\":\"1\",\"event\":\"session_start\",\"session_id\":\"$SID\",\"event_id\":\"$(uuid)\",\"timestamp\":\"$(now)\"}"
      send "{\"schema_version\":\"1\",\"event\":\"session_done\",\"session_id\":\"$SID\",\"event_id\":\"$(uuid)\",\"timestamp\":\"$(now)\",\"elapsed_ms\":1000}"
      echo "    done フェーズに遷移しました。doneAutoTransitionDelay(4秒) + 余裕1秒 を待ちます..."
      sleep 5
      echo "    期待: 顔ピンクブラウン、視線 f02_rightDown 固定（softFixed）、吹き出しなし"
      wait_or_enter
      ;;
    *)
      echo "ERROR: 不明なフェーズ: $SINGLE_PHASE" >&2
      echo "  有効なフェーズ: thinking, responding, working, error, done, idle" >&2
      exit 1
      ;;
  esac
else
  phase_thinking
  phase_working
  phase_tool_end
  phase_error
  phase_done
  phase_idle
fi

echo "=== テスト完了 ==="
