# Clabotch（クラボッチ）設計仕様書 v3

> Claude + bot + っち（たまごっちリスペクト）  
> macOSメニューバー常駐型 Claude Code マスコット  
>  
> **v3**: v2（章10〜12）にハードニングパッチ（章13）を統合した最終仕様。  
> 実装直前の状態として本ドキュメントを基準とする。

---

## 目次

1. [コンセプト](#1-コンセプト)
2. [既存調査](#2-既存調査)
3. [キャラクター仕様](#3-キャラクター仕様)
4. [フレーム一覧（全14枚）](#4-フレーム一覧全14枚)
5. [アニメーション定義](#5-アニメーション定義)
6. [マスコット状態一覧（v3修正済み）](#6-マスコット状態一覧v3修正済み)
7. [技術アーキテクチャ](#7-技術アーキテクチャ)
8. [実装方針](#8-実装方針)
9. [開発ロードマップ（v3修正済み）](#9-開発ロードマップv3修正済み)
10. [Event Schema](#10-event-schema)
11. [Permission / Fallback Spec](#11-permission--fallback-spec)
12. [MVP Definition](#12-mvp-definition)
13. [実装前ハードニング（v3追補）](#13-実装前ハードニングv3追補)

---

## 1. コンセプト

**「Claude Code が働いているのをそっと見守るメニューバーの住人」**

- macOS メニューバーに常駐し、邪魔にならないサイズで存在する
- Claude Code の動作状態（待機・実行・思考・完了・エラー）を目の表情だけで表現
- ターミナルウィンドウの方向に視線を向けて「作業している感」を伝える
- タスク完了時にジャンプして吹き出しで報告する

---

## 2. 既存調査

| アプリ | 配置 | Mac mini対応 | 特徴 |
|--------|------|-------------|------|
| **Notchi** | ノッチ固定 | ❌ | Claude Code hooks連携、感情分析あり |
| **Clawdachi** | 画面上浮遊 | ✅ | ピクセルアート、Spotify連動ダンス |
| **Clabotch** | メニューバー | ✅ | 視線追跡、ジャンプ通知、完全ドット描画 |

Clabotchの差別化：**メニューバー固定 × 視線が動く × 作業の邪魔ゼロ**

---

## 3. キャラクター仕様

### キャンバスサイズ

```
outer（NSStatusItem枠）: 22 × 14 px（論理ピクセル）
face（顔）            : 16 × 12 px  at (3, 1)
左目ソケット（白目）   :  4 ×  8 px  at (5, 3)
右目ソケット（白目）   :  4 ×  8 px  at (13, 3)
瞳（左右各）          :  2 ×  6 px  ← フレームにより座標が変わる
```

### カラーパレット

| パーツ | カラーコード | 用途 |
|--------|-------------|------|
| `#B07878` | 顔（通常） | ベース顔色 |
| `#C08888` | 顔（完了） | 少し明るめ |
| `#C06868` | 顔（エラー） | 赤みを強調 |
| `#906060` | 顔（スリープ） | 暗め |
| `#F0F0F0` | 白目 | アイソケット |
| `#1A1A1A` | 瞳 | ほぼ黒 |
| `#E94560` | エラーX | 赤 |
| `#5577AA` | 思考ドット | 青系 |

### 重要な設計方針

> **PNG素材ゼロ — 全フレームをSwiftコードで描画**  
> Retina（@2x/@3x）対応も `dot = bounds.width / 22.0` 一発で完結

> **瞳移動は座標計算禁止 — フレーム丸ごと切り替え**  
> 連続オフセットだと中間値（1.5dotなど）が発生してドットが崩れるため、
> 4枚の瞳座標セットを定義して切り替えるだけにする

---

## 4. フレーム一覧（全14枚）

実測値：`charactor--01.png` 〜 `charactor--14.png` を Pillow でピクセル読み取り

### 視線フレーム（02〜05）

瞳サイズ 2×6px。座標は左ソケット `(sx=5, sy=3)` を基準に記載。

| フレーム | 画像 | 瞳位置 | Swift座標 | 用途 |
|----------|------|--------|-----------|------|
| `01` | charactor-01 | 中央 | `(sx+1, sy+1)` | 中央固定・error/sleeping |
| `02` | charactor-02 | **右下** | `pupil(sx+2, sy+2, 2, 6)` | idle固定・通常待機 |
| `03` | charactor-03 | **左下** | `pupil(sx, sy+2, 2, 6)` | 左方向 |
| `04` | charactor-04 | **左上** | `pupil(sx, sy, 2, 6)` | 左上方向 |
| `05` | charactor-05 | **右上** | `pupil(sx+2, sy, 2, 6)` | 思考・右上 |

```
frame02:      frame03:      frame04:      frame05:
y3: WWWW      y3: WWWW      y3: PPWW      y3: WWPP
y4: WWWW      y4: WWWW      y4: PPWW      y4: WWPP
y5: WWPP  →   y5: PPWW  →   y5: PPWW  →   y5: WWPP
y6: WWPP      y6: PPWW      y6: PPWW      y6: WWPP
y7: WWPP      y7: PPWW      y7: PPWW      y7: WWPP
y8: WWPP      y8: PPWW      y8: PPWW      y8: WWPP
y9: WWPP      y9: PPWW      y9: WWWW      y9: WWWW
y10: WWPP     y10: PPWW     y10: WWWW     y10: WWWW
```

### まばたきフレーム（06）

| フレーム | 画像 | 内容 |
|----------|------|------|
| `06` | charactor-06 | 白目はそのまま。中央 y7 に **横線1dot（瞳色）** のみ |

> まばたきは `open → half → almost → closed(06) → almost → half → open` の6ステップ

### エラー・表情フレーム（07〜14）

| フレーム | 画像 | パターン | 用途 |
|----------|------|---------|------|
| `07` | charactor-07 | 中央2×2に小さい× | ERROR（控えめ・基点） |
| `08` | charactor-08 | y7に `WPPW`（中央に2dot） | DONE・驚き |
| `09` | charactor-09 | 左目：ジグザグ縦線 / 右目：PP列 | アニメフレームA |
| `10` | charactor-10 | 上半分に× (`WPPW/PWWP`) | ERROR（上） |
| `11` | charactor-11 | 下半分に× (`PWWP/WPPW`) | ERROR（下） |
| `12` | charactor-12 | 両目に渦巻き状ドット | くるくるアニメB |
| `13` | charactor-13 | 斜め右下がりパターン | くるくるアニメC |
| `14` | charactor-14 | 斜め左下がりパターン（13の逆） | くるくるアニメD |

**エラーアニメ**：`07 → 10 → 11 → 10 → 07`（上下シェイク）  
**完了アニメ**：`08 → 09 → 12 → 13 → 14 → 13 → 12`（くるくる）

---

## 5. アニメーション定義

### まばたき（BlinkController）

```
open ─(60ms)→ half ─(60ms)→ almost ─(90ms)→ closed
     ←(60ms)─ half ←(60ms)─ almost ←────────
```
- 次のまばたきまで 2.8〜5.5秒 ランダム待機
- 視線変更と**完全独立**して動作

### 視線追跡（GazeController）

```swift
// ターミナルとアイコンの相対位置を4フレームに量子化
(右下) → frame02
(左下) → frame03
(左上) → frame04
(右上) → frame05
```

- `atan2(dy, dx)` で方向計算 → 4択 enum に変換
- **ClabotchEyeView 内に座標計算は一切なし**

### ジャンプ（DONEイベント）

- NSStatusItem の Y オフセットに バウンスイージングを適用
- ↑ 6px → ↑ 12px → ↑ 4px → 原点 の4ステップ
- 完了後に吹き出し（NSWindow, borderless）が 3秒表示

---

## 6. マスコット状態一覧（v3修正済み）

> **v1/v2 との変更点：**
> - `idle` 視線を `tracking` から `fixed(.f02_rightDown)` に修正
> - `error` 視線を曖昧な "center" から `fixed(.f01_center)` に明示
> - `MascotPhase` enum の型を確定

| 状態（MascotPhase） | トリガー | 視線 | まばたき | 表情フレーム | 吹き出し例 |
|-------------------|---------|------|---------|------------|-----------|
| `.idle` | 初期値 / done後 | `fixed(.f02_rightDown, .mascotStateOverride)` | 通常 | frame02 | — |
| `.thinking` | session_start / tool_end成功後 | `tracking` or fallback | 通常 | frame05傾向 | 「考えてます...」 |
| `.working(tool)` | tool_start受信 | `tracking` or fallback | 通常 | frame02〜05（動的） | 「{tool} 実行中...」 |
| `.done(ms)` | session_done受信 | `fixed(.f02_rightDown, .mascotStateOverride)` | 通常 | frame08→09→12→13→14 | 「完了！(3分42秒)」 or 「完了！」 |
| `.error(tool, msg)` | tool_end is_error=true | `fixed(.f01_center, .mascotStateOverride)` | 停止 | frame07→10→11→10→07 | 「エラーが出ました…」 |
| `.sleeping` | 無操作タイマー（セッションなし時のみ） | `fixed(.f01_center, .mascotStateOverride)` | 停止 | frame06（閉じ） | — |

---

## 7. 技術アーキテクチャ

### データフロー

```
Claude Code
  └─ hooks (shell scripts in ~/.claude/hooks/)
       └─ Unix Socket ($TMPDIR/clabotch.sock)  ← /tmp 廃止（v2修正）
            └─ HookServer (Swift)
                 └─ EventParser
                      └─ StateMachine
                           ├─ ClabotchEyeView（描画）
                           ├─ BlinkController（まばたき）
                           ├─ GazeController（視線）
                           └─ BubbleWindow（吹き出し）
```

### 主要コンポーネント

| コンポーネント | 役割 |
|----------------|------|
| `NSStatusItem` | メニューバー常駐 |
| `ClabotchEyeView: NSView` | ドット描画本体 |
| `BlinkController` | まばたきタイマー管理 |
| `GazeController` | 方向計算→4択量子化・fallback管理 |
| `HookServer` | Unix Socket受信 |
| `EventParser` | JSON→ClabotchEvent変換・malformed破棄 |
| `StateMachine` | epoch guard付き状態遷移 |
| `BubbleWindow: NSWindow` | 吹き出し表示（borderless/transparent） |

---

## 8. 実装方針

### ドット描画の核心原則

```swift
// ✅ 正しい：フレーム丸ごと切り替え
case .f02_rightDown: px(sx+2, sy+2, 2, 6)
case .f03_downLeft:  px(sx,   sy+2, 2, 6)
case .f04_upLeft:    px(sx,   sy,   2, 6)
case .f05_upRight:   px(sx+2, sy,   2, 6)

// ❌ 禁止：連続オフセット計算
// pupil.x += delta  // 中間値が発生してドットが崩れる
```

### Retina対応

```swift
let dot = min(bounds.width / 22.0, bounds.height / 14.0)
// @2x で自動的に dot=2.0 になる
```

---

## 9. 開発ロードマップ（v3修正済み）

> **v2 からの変更：**  
> - v0.1 を 2日→3日（Warp AX API検証バッファ）  
> - v0.3 を 2日→3日（StateMachineリファクタ）  
> - v1.0 を 2日→4〜5日（**Notarization 工数追加**）

| Phase | 期間 | 内容 | リスク |
|-------|------|------|--------|
| **PoC** | 1日 | NSStatusItemにフレーム01を表示 + まばたき + Socket受信確認 | 低 |
| **v0.1** | 3日 | 視線追跡（frame02〜05）+ Hook受信 + StateMachine結合 | **Warp AX互換性** |
| **v0.2** | 2日 | DONE/ERROR アニメ + ジャンプ + 吹き出し | 低 |
| **v0.3** | 3日 | 複数セッション並列 + 作業時間表示 | StateMachineリファクタ |
| **v1.0** | 4〜5日 | 設定画面 + LaunchAgent + **Notarization + DMG** | Apple Developer証明書 |

### Notarization 工数内訳（v1.0）

- Apple Developer Program（未登録なら ¥13,800/年）
- `xcrun notarytool submit` → Apple処理（30分〜2時間）
- `xcrun stapler staple` でDMGに結果を埋め込み
- Gatekeeper テスト（別端末推奨）

### 完了済み

- [x] Notchi / Clawdachi 調査
- [x] 名前「Clabotch」決定
- [x] 全フレームのピクセルマップ実測（Pillow）
- [x] SwiftコードによるフレームSwap方式の設計
- [x] `ClabotchEyeView.swift` v3

### NEXT（実装順 — §13.7 修正済み）

- [ ] **Hook 環境変数の実機確認**（最優先 — §13.7参照）
- [ ] HookServer + EventParser（malformed破棄含む）
- [ ] Single-session StateMachine（epoch guard含む）
- [ ] GazeController（Terminal/iTerm2/WezTerm先行）
- [ ] Warp AX属性ダンプ調査

---

## 10. Event Schema

### 10.1 設計方針

現行 hook は `tool_start` / `tool_end` / `done` の3種類しか送っていないが、  
UI は `idle` / `thinking` / `working` / `done` / `error` / `sleeping` の6状態を扱う。

#### 状態とイベントの対応表

| UI状態 | トリガーイベント | 補足 |
|--------|----------------|------|
| `idle` | 初期値 / `session_done` 受信後 | アプリ起動でidle |
| `thinking` | `session_start` 受信 / `tool_end`（成功）後 | 推定状態（§13.1参照） |
| `working` | `tool_start` 受信 | ツール実行中 |
| `done` | `session_done` 受信 | 完了アニメ後 → idle |
| `error` | `tool_end`（is_error=true）受信 | エラーアニメ後 → thinking |
| `sleeping` | クライアントサイドタイマー | セッションなし時のみ（§13.5参照） |

#### `thinking` の実現方法

Claude Code には thinking hook が存在しない。  
`session_start` = **「最初の PreToolUse が来たタイミングでセッションIDが新規かを確認して送るシェルラッパー方式」** で実装する。

---

### 10.2 JSON スキーマ定義（v1）

#### 共通フィールド

| フィールド | 型 | 必須 | 説明 |
|------------|-----|------|------|
| `schema_version` | string | ✅ | 常に `"1"` |
| `event` | string enum | ✅ | 後述 |
| `session_id` | string | ✅ | `$SESSION_ID` |
| `event_id` | string | ✅ | UUID v4（重複除去用） |
| `timestamp` | string (ISO8601) | ✅ | UTC |

#### イベント別フィールド

```
event: "session_start"  → 共通フィールドのみ

event: "tool_start"     → tool_name: string

event: "tool_end"       → tool_name: string
                          duration_ms: number
                          is_error: bool
                          error_message: string | null

event: "session_done"   → elapsed_ms: number
```

#### サンプル JSON

```json
{ "schema_version":"1", "event":"session_start",
  "session_id":"sess_abc123", "event_id":"550e8400-...", "timestamp":"2026-03-10T09:00:00Z" }

{ "schema_version":"1", "event":"tool_start",
  "session_id":"sess_abc123", "event_id":"550e8400-...1", "timestamp":"2026-03-10T09:00:05Z",
  "tool_name":"Write" }

{ "schema_version":"1", "event":"tool_end",
  "session_id":"sess_abc123", "event_id":"550e8400-...2", "timestamp":"2026-03-10T09:00:06Z",
  "tool_name":"Write", "duration_ms":842, "is_error":false, "error_message":null }

{ "schema_version":"1", "event":"tool_end",
  "session_id":"sess_abc123", "event_id":"550e8400-...3", "timestamp":"2026-03-10T09:00:07Z",
  "tool_name":"Bash", "duration_ms":201, "is_error":true, "error_message":"tool failed" }

{ "schema_version":"1", "event":"session_done",
  "session_id":"sess_abc123", "event_id":"550e8400-...4", "timestamp":"2026-03-10T09:03:42Z",
  "elapsed_ms":222000 }
```

---

### 10.3 受信側パーサー（Swift）

```swift
// MARK: - ClabotchEvent.swift

enum ClabotchEvent {
    case sessionStart(sessionID: String)
    case toolStart(sessionID: String, toolName: String)
    case toolEnd(sessionID: String, toolName: String, durationMs: Int, isError: Bool, errorMessage: String?)
    case sessionDone(sessionID: String, elapsedMs: Int)
    case unknown(raw: [String: Any])
}

struct EventParser {
    static func parse(_ data: Data) -> ClabotchEvent? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let event = json["event"] as? String,
            let sessionID = json["session_id"] as? String
        else { return nil }  // malformed → 黙って破棄

        switch event {
        case "session_start":
            return .sessionStart(sessionID: sessionID)
        case "tool_start":
            guard let toolName = json["tool_name"] as? String else { return nil }
            return .toolStart(sessionID: sessionID, toolName: toolName)
        case "tool_end":
            guard
                let toolName   = json["tool_name"] as? String,
                let durationMs = json["duration_ms"] as? Int,
                let isError    = json["is_error"] as? Bool
            else { return nil }
            return .toolEnd(
                sessionID: sessionID, toolName: toolName,
                durationMs: durationMs, isError: isError,
                errorMessage: json["error_message"] as? String
            )
        case "session_done":
            let elapsedMs = json["elapsed_ms"] as? Int ?? 0
            return .sessionDone(sessionID: sessionID, elapsedMs: elapsedMs)
        default:
            return .unknown(raw: json)
        }
    }
}
```

---

### 10.4 Hook シェル設定（v3 最終版）

> **変更点（v1→v3）：**
> - `/tmp` → `$TMPDIR` に変更
> - `echo` → `printf` + `json_escape` に変更
> - `python3 uuid` → `uuidgen` に変更（macOS標準、依存ゼロ）
> - `session_start` をシェル側で送る仕組みを追加

#### 共通 helper（`~/.claude/hooks/clabotch_lib.sh`）

```bash
#!/usr/bin/env bash

SOCK="${TMPDIR}clabotch.sock"
SESSION_REGISTRY="${TMPDIR}clabotch_sessions"

generate_uuid() {
  uuidgen | tr '[:upper:]' '[:lower:]'
}

json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

send_json() {
  [[ -S "$SOCK" ]] || return 0
  nc -U "$SOCK" >/dev/null 2>&1 || true
}
```

#### `~/.claude/hooks/clabotch_pre_tool.sh`

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/clabotch_lib.sh"

SESSION_START_FILE="${SESSION_REGISTRY}/${SESSION_ID}"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EPOCH=$(date +%s)

# 新規セッション検知 → session_start を送る
mkdir -p "$SESSION_REGISTRY"
if [[ ! -f "$SESSION_START_FILE" ]]; then
  echo "$EPOCH" > "$SESSION_START_FILE"
  printf '{"schema_version":"1","event":"session_start","session_id":"%s","event_id":"%s","timestamp":"%s"}\n' \
    "$SESSION_ID" "$(generate_uuid)" "$NOW" | send_json
fi

# tool_start を送る
TOOL_ESCAPED=$(json_escape "${TOOL_NAME:-unknown}")
printf '{"schema_version":"1","event":"tool_start","session_id":"%s","event_id":"%s","timestamp":"%s","tool_name":"%s"}\n' \
  "$SESSION_ID" "$(generate_uuid)" "$NOW" "$TOOL_ESCAPED" | send_json
```

#### `~/.claude/hooks/clabotch_post_tool.sh`

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/clabotch_lib.sh"

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TOOL_ESCAPED=$(json_escape "${TOOL_NAME:-unknown}")

IS_ERROR="false"
ERROR_JSON="null"
if [[ "${EXIT_CODE:-0}" != "0" ]]; then
  IS_ERROR="true"
  ERROR_JSON='"tool failed"'
fi

printf '{"schema_version":"1","event":"tool_end","session_id":"%s","event_id":"%s","timestamp":"%s","tool_name":"%s","duration_ms":%s,"is_error":%s,"error_message":%s}\n' \
  "$SESSION_ID" "$(generate_uuid)" "$NOW" "$TOOL_ESCAPED" \
  "${TOOL_DURATION_MS:-0}" "$IS_ERROR" "$ERROR_JSON" | send_json
```

#### `~/.claude/hooks/clabotch_stop.sh`

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/clabotch_lib.sh"

SESSION_START_FILE="${SESSION_REGISTRY}/${SESSION_ID}"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

ELAPSED_MS=0
if [[ -f "$SESSION_START_FILE" ]]; then
  START_EPOCH=$(cat "$SESSION_START_FILE")
  ELAPSED_MS=$(( ($(date +%s) - START_EPOCH) * 1000 ))
  rm -f "$SESSION_START_FILE"
fi

printf '{"schema_version":"1","event":"session_done","session_id":"%s","event_id":"%s","timestamp":"%s","elapsed_ms":%d}\n' \
  "$SESSION_ID" "$(generate_uuid)" "$NOW" "$ELAPSED_MS" | send_json
```

#### `~/.claude/settings.json` hooks セクション

```json
{
  "hooks": {
    "PreToolUse":  [{ "command": "~/.claude/hooks/clabotch_pre_tool.sh" }],
    "PostToolUse": [{ "command": "~/.claude/hooks/clabotch_post_tool.sh" }],
    "Stop":        [{ "command": "~/.claude/hooks/clabotch_stop.sh" }]
  }
}
```

> ⚠️ **実装前に必ず確認（§13.7参照）**：  
> `$SESSION_ID` / `$TOOL_NAME` / `$EXIT_CODE` / `$TOOL_DURATION_MS` の実際の変数名は  
> Claude Code のバージョンによって異なる可能性がある。PoC前に実機で echo して確認する。

---

## 11. Permission / Fallback Spec

### 11.1 アクセシビリティ権限の状態定義

```swift
// MARK: - GazePermissionStatus.swift

enum GazePermissionStatus {
    case notDetermined   // 未確認（初回起動・未リクエスト）
    case granted         // 許可済み → フル視線追跡
    case denied          // 拒否済み → 固定視線 frame02
}

// UserDefaults キー
private enum PermissionKeys {
    static let didRequestAccessibility = "didRequestAccessibility"
}
```

### 11.2 権限判定ロジック（v3修正版）

> **v2 バグ修正：** 旧 `checkPermission()` は初回 `notDetermined` を即 `denied` に潰していた。  
> OS状態と「リクエスト済みか」フラグを分離して3状態を正確に管理する。

```swift
private func checkPermission() {
    let trusted   = AXIsProcessTrusted()
    let didRequest = UserDefaults.standard.bool(forKey: PermissionKeys.didRequestAccessibility)

    if trusted {
        permissionStatus = .granted
    } else if didRequest {
        permissionStatus = .denied
    } else {
        permissionStatus = .notDetermined
    }
}

func requestPermissionIfNeeded(completion: @escaping (GazePermissionStatus) -> Void) {
    checkPermission()
    guard permissionStatus == .notDetermined else { completion(permissionStatus); return }

    // リクエスト済みフラグを先にセット
    UserDefaults.standard.set(true, forKey: PermissionKeys.didRequestAccessibility)
    let _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true] as CFDictionary)

    // ダイアログ応答待ち（1秒後に再チェック）
    // Note: ユーザーがSystem Settings操作に時間がかかる場合は
    // pollTimer での継続チェック（0.5秒間隔）に委ねる
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
        self?.checkPermission()
        completion(self?.permissionStatus ?? .denied)
    }
}
```

### 11.3 視線モード定義

```swift
// MARK: - GazeMode.swift

enum GazeMode: Equatable {
    case tracking
    case fixed(GazeFrame, reason: FixedGazeReason)
}

enum FixedGazeReason {
    case permissionDenied
    case permissionNotDetermined  // 追加（v3）: notDetermined中は自然な右下固定
    case terminalNotFound
    case terminalInOtherSpace
    case terminalMinimized
    case unsupportedTerminal
    case mascotStateOverride      // error/sleeping/idle など状態側が制御
}
```

### 11.4 各シナリオの振る舞い仕様

| シナリオ | GazeMode | 表示フレーム |
|---------|----------|------------|
| 権限許可 + ターミナル検出 | `.tracking` | frame02〜05（動的） |
| 権限許可 + ターミナル未検出 | `.fixed(.f01_center, .terminalNotFound)` | frame01 |
| 権限許可 + 別 Space | `.fixed(.f01_center, .terminalInOtherSpace)` | frame01 |
| 権限許可 + 最小化 | `.fixed(.f01_center, .terminalMinimized)` | frame01 |
| 権限許可 + Warp | `.fixed(.f02_rightDown, .unsupportedTerminal)` | frame02 |
| 権限 notDetermined | `.fixed(.f02_rightDown, .permissionNotDetermined)` | frame02（自然） |
| 権限拒否 | `.fixed(.f02_rightDown, .permissionDenied)` | frame02 |
| error 状態 | `.fixed(.f01_center, .mascotStateOverride)` | frame07→10→11 |
| sleeping 状態 | `.fixed(.f01_center, .mascotStateOverride)` | frame06 |

### 11.5 GazeController — Warp 分離版（v3修正）

```swift
// MARK: - GazeController.swift

final class GazeController {

    // MVP: 確認済み対応ターミナル
    private let supportedBundles: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "org.wezfurlong.wezterm"
    ]

    // AX属性ダンプ後に supportedBundles へ昇格させる候補
    private let tentativeBundles: Set<String> = [
        "dev.warp.desktop"
    ]

    // frontmost app を先に分類してから AX を呼ぶ
    private func classifyFrontmostTerminal() -> FixedGazeReason? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return .terminalNotFound
        }
        let bundleID = frontApp.bundleIdentifier ?? ""

        if tentativeBundles.contains(bundleID) { return .unsupportedTerminal }
        guard supportedBundles.contains(bundleID) else { return .terminalNotFound }
        return nil  // nil = 対応ターミナルが最前面 → AX取得へ進む
    }

    // window取得後の失敗理由を状況別に分ける
    // window 0件 → .terminalMinimized
    // position/size取得不可 → .terminalInOtherSpace
    private func findFrontmostTerminalCenter(pid: pid_t) -> (CGPoint?, FixedGazeReason?) {
        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
            let windows = windowsRef as? [AXUIElement],
            !windows.isEmpty
        else {
            return (nil, .terminalMinimized)
        }

        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(windows[0], kAXPositionAttribute as CFString, &posRef) == .success,
            AXUIElementCopyAttributeValue(windows[0], kAXSizeAttribute as CFString, &sizeRef) == .success
        else {
            return (nil, .terminalInOtherSpace)
        }

        var pos  = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef  as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize,  &size)
        return (CGPoint(x: pos.x + size.width/2, y: pos.y + size.height/2), nil)
    }

    // 視線方向を4択に量子化（座標計算はここのみ）
    private func quantizeDirection(from origin: CGPoint, to target: CGPoint) -> GazeFrame {
        let dx =  (target.x - origin.x)
        let dy = -(target.y - origin.y)  // macOS座標系Y反転
        switch (dx >= 0, dy >= 0) {
        case (true,  false): return .f02_rightDown
        case (false, false): return .f03_leftDown
        case (false, true):  return .f04_leftUp
        case (true,  true):  return .f05_rightUp
        default:             return .f02_rightDown
        }
    }

    var statusItemCenterProvider: (() -> CGPoint?)?
    private(set) var gazeFrame: GazeFrame = .f02_rightDown
    private(set) var mode: GazeMode = .fixed(.f02_rightDown, reason: .terminalNotFound)
}
```

### 11.6 フォールバック優先順位

```
1. mascotStateOverride（error/sleeping/idle など状態側が制御）
2. permissionDenied / permissionNotDetermined → frame02 固定
3. tracking（AX APIでリアルタイム追跡）
4. terminalInOtherSpace / terminalMinimized → frame01 固定
5. terminalNotFound → frame01 固定
6. unsupportedTerminal → frame02 固定
```

### 11.7 オンボーディング UI 仕様

```
┌──────────────────────────────────────────────┐
│  🤖  Clabotch へようこそ                       │
│                                              │
│  Claude Code の作業をメニューバーで見守ります。   │
│                                              │
│  視線追跡機能を使うには                         │
│  アクセシビリティの許可が必要です。               │
│  ※ 許可しなくても機能の95%は動作します。          │
│                                              │
│        [後で]            [許可する]            │
└──────────────────────────────────────────────┘
```

- 「許可する」 → `requestPermissionIfNeeded()` を呼び出す
- 「後で」 → `notDetermined` のまま起動。メニューバー右クリックで再表示可能

---

## 12. MVP Definition

### 12.1 状態定義

```swift
// MARK: - MascotPhase.swift

enum MascotPhase: Equatable {
    case idle
    case thinking
    case working(toolName: String)
    case done(elapsedMs: Int)
    case error(toolName: String, message: String?)
    case sleeping
}

struct SessionState: Equatable {
    let sessionID: String
    var phase: MascotPhase
    let startedAt: Date
    var lastEventAt: Date
}
```

### 12.2 StateMachine（v3 epoch guard + sleeping制限 版）

```swift
// MARK: - StateMachine.swift

final class StateMachine {

    private(set) var session: SessionState?
    private(set) var displayPhase: MascotPhase = .idle

    private var sleepTimer: Timer?
    private var pendingTransition: DispatchWorkItem?   // キャンセル可能な遅延遷移
    private var transitionEpoch: UInt = 0              // レース対策のエポック番号

    private let sleepThreshold: TimeInterval = 300     // 5分

    var onPhaseChanged: ((MascotPhase) -> Void)?

    // MARK: - Public

    func handle(event: ClabotchEvent) {
        // 新イベントで pending transition を必ずキャンセル
        transitionEpoch &+= 1
        pendingTransition?.cancel()
        pendingTransition = nil
        resetSleepTimer()

        switch event {

        case .sessionStart(let sessionID):
            session = SessionState(
                sessionID: sessionID,
                phase: .thinking,
                startedAt: Date(),
                lastEventAt: Date()
            )
            transition(to: .thinking)

        case .toolStart(let sessionID, let toolName):
            guard isActiveSession(sessionID) else { return }
            session?.lastEventAt = Date()
            session?.phase = .working(toolName: toolName)
            transition(to: .working(toolName: toolName))

        case .toolEnd(let sessionID, let toolName, _, let isError, let errorMessage):
            guard isActiveSession(sessionID) else { return }
            session?.lastEventAt = Date()
            if isError {
                let p = MascotPhase.error(toolName: toolName, message: errorMessage)
                session?.phase = p
                transition(to: p)
                // エラーアニメ（2.5秒後）→ thinking に戻す
                scheduleAutoTransition(to: .thinking, after: 2.5, expectedSessionID: sessionID)
            } else {
                session?.phase = .thinking
                transition(to: .thinking)
            }

        case .sessionDone(let sessionID, let elapsedMs):
            // unknown session の Stop も ephemeral completion として処理
            if isActiveSession(sessionID) { session = nil }
            transition(to: .done(elapsedMs: elapsedMs))
            scheduleAutoTransition(to: .idle, after: 4.0, expectedSessionID: nil)

        case .unknown:
            break
        }
    }

    // MARK: - Private

    private func isActiveSession(_ id: String) -> Bool {
        session?.sessionID == id
    }

    private func transition(to phase: MascotPhase) {
        guard displayPhase != phase else { return }
        displayPhase = phase
        DispatchQueue.main.async { [weak self] in self?.onPhaseChanged?(phase) }
    }

    private func scheduleAutoTransition(
        to phase: MascotPhase,
        after delay: TimeInterval,
        expectedSessionID: String?
    ) {
        let epoch = transitionEpoch
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.transitionEpoch == epoch else { return }    // epoch不一致 → 無効
            guard expectedSessionID == nil
               || self.session?.sessionID == expectedSessionID
            else { return }
            self.transition(to: phase)
        }
        pendingTransition = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // sleeping はセッションが存在しない時のみ発火
    private func resetSleepTimer() {
        sleepTimer?.invalidate()
        if displayPhase == .sleeping {
            transition(to: session != nil ? .thinking : .idle)
        }
        guard session == nil else { return }  // ← active session中はsleepタイマーを立てない
        sleepTimer = Timer.scheduledTimer(withTimeInterval: sleepThreshold, repeats: false) { [weak self] _ in
            guard self?.session == nil else { return }
            self?.transition(to: .sleeping)
        }
    }
}
```

### 12.3 将来の複数セッション対応（v0.3 向けスケルトン）

```swift
// MARK: - MultiSessionStateMachine.swift（v0.3スケルトン）

extension MascotPhase {
    var displayPriority: Int {
        switch self {
        case .error:    return 0
        case .working:  return 1
        case .thinking: return 2
        case .done:     return 3
        case .idle:     return 4
        case .sleeping: return 5
        }
    }
}

final class MultiSessionStateMachine {
    private var sessions: [String: SessionState] = [:]

    var displayPhase: MascotPhase {
        sessions.values.map(\.phase)
            .min { $0.displayPriority < $1.displayPriority }
            ?? .idle
    }
    // v0.3 で実装
}
```

### 12.4 MVP スコープ

#### 含めるもの

| 機能 | 詳細 |
|------|------|
| メニューバー常駐 | NSStatusItem、22×14px |
| フレーム描画 | frame01〜06（視線4種＋まばたき） |
| まばたき | BlinkController、2.8〜5.5秒ランダム |
| 視線追跡 | GazeController（AX API / fallback） |
| Hook受信 | Unix Socket（$TMPDIR使用） |
| 状態遷移 | StateMachine（epoch guard付き） |
| 完了アニメ | frame08→09→12→13→14、ジャンプ、吹き出し |
| エラーアニメ | frame07→10→11シェイク |
| sleeping | 5分タイマー（セッションなし時のみ） |

#### 含めないもの（v0.3 以降）

| 機能 | 理由 |
|------|------|
| 複数セッション並列 | StateMachine拡張が必要 |
| 設定画面・LaunchAgent | v1.0スコープ |
| Warp完全対応 | AX属性ダンプ確認後 |
| Apple公証 / DMG | v1.0スコープ（工数4〜5日） |

---

## 13. 実装前ハードニング（v3追補）

### 13.1 イベント観測の限界と MVP での扱い

Claude Code hooks だけでは、**ツール未使用セッションの開始時刻**と**純粋な thinking 開始時刻**は正確には観測できない。

| 項目 | MVP での扱い |
|------|--------------|
| `session_start` | 最初の `PreToolUse` 到達時に擬似生成するローカルイベント |
| ツール未使用セッション | `Stop` のみ観測可能。経過時間は `0` |
| `thinking` | hook 起点の推定状態。厳密な開始時刻保証はしない |
| 作業時間表示 | `elapsed_ms > 0` のときのみ吹き出しに表示 |

#### 吹き出し文言ルール

- `elapsed_ms > 0` → `完了！(3分42秒)`
- `elapsed_ms == 0` → `完了！`

#### unknown session の session_done

`session_done` を受信した時点でSessionStateが存在しない場合も、  
ephemeral completion として完了アニメを出す（§12.2のコード参照）。

---

### 13.2 Hook 送信の堅牢化（§10.4 への追補）

v3 では以下を確定する：

1. `uuidgen` を使用（`python3` 依存除去）
2. `json_escape` helper で `"` `\n` `\\` をエスケープ
3. 送信は **best-effort**（ソケットがなければ黙って終了）
4. `error_message` 詳細取得は MVP 未対応（`"tool failed"` 固定）

---

### 13.3 権限状態の3値管理（§11.2 への追補）

> v2 の `checkPermission()` バグを修正済み（§11.2 参照）。

- `start()` では prompt を出さない
- オンボーディングの `[許可する]` 操作でのみ prompt を出す
- `notDetermined` の間は `permissionNotDetermined` 理由で frame02 固定（自然に見える）
- `pollTimer`（0.5秒間隔）で継続的に `checkPermission()` を呼び、権限変更を検知する

---

### 13.4 Gaze fallback の分類（§11.5 への追補）

Warp を `supportedBundles` に含めない（`tentativeBundles` で管理）。  
window取得失敗の理由は4種に分類して明示する（§11.5の表参照）。

---

### 13.5 StateMachine レース対策（§12.2 への追補）

- `transitionEpoch` で遅延遷移の無効化を保証
- `pendingTransition: DispatchWorkItem?` でキャンセル可能に
- `sleeping` は `session == nil` 時のみ発火

---

### 13.6 MVP の既知制約（明文化）

- ツール未使用セッションの経過時間は正確に測れない
- Warp は正式対応前は `.unsupportedTerminal` で固定視線に落とす
- `error_message` 詳細は v1.0 以降で改善余地あり
- `thinking` は厳密な開始時刻保証なし（推定状態）

---

### 13.7 実装順（最終確定）

> 「机上のスキーマ修正を最小化するため、hook実測を最優先にする」

| 順序 | 作業 | 確認事項 |
|------|------|---------|
| 1 | **Hook 環境変数の実機確認** | `$SESSION_ID` `$TOOL_NAME` `$EXIT_CODE` `$TOOL_DURATION_MS` が実際に存在するか確認。存在しない変数はデフォルト値で代替 |
| 2 | HookServer + EventParser | malformed JSON の黙殺、unknown event のログ記録 |
| 3 | Single-session StateMachine | epoch guard + sleeping制限 の動作確認 |
| 4 | GazeController | Terminal / iTerm2 / WezTerm 先行対応 |
| 5 | Warp AX調査 | `AXUIElement` 属性ダンプ → 対応可否を判断して `tentativeBundles` から昇格 |

---

## 成果物ファイル（v3時点）

| ファイル | 内容 |
|----------|------|
| `clabotch_design_doc_v3.md` | 本仕様書（v1〜v3統合） |
| `clabotch_sprites_v3.svg` | スプライトシート設計図 |
| `ClabotchEyeView_v3.swift` | 描画エンジン本体 |
| `~/.claude/hooks/clabotch_lib.sh` | hook共通helper |
| `~/.claude/hooks/clabotch_pre_tool.sh` | PreToolUse hook |
| `~/.claude/hooks/clabotch_post_tool.sh` | PostToolUse hook |
| `~/.claude/hooks/clabotch_stop.sh` | Stop hook |

---

*Clabotch — MIT License — 2026 Nakata*  
*v3: 2026-03-10 — Codex hardening patch 統合*
