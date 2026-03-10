# Clabotch（クラボッチ）設計仕様書 v4

> Claude + bot + っち（たまごっちリスペクト）  
> macOSメニューバー常駐型 Claude Code マスコット  
>  
> **v4**: v3にIPCフレーミング・event_id重複除去・single-session guardを追加した実装直前の最終仕様。  
> 本ドキュメントのみを参照して実装を開始できる状態を目指す。

---

## 目次

1. [コンセプト](#1-コンセプト)
2. [既存調査](#2-既存調査)
3. [キャラクター仕様](#3-キャラクター仕様)
4. [フレーム一覧（全14枚）](#4-フレーム一覧全14枚)
5. [アニメーション定義](#5-アニメーション定義)
6. [マスコット状態一覧](#6-マスコット状態一覧)
7. [技術アーキテクチャ](#7-技術アーキテクチャ)
8. [実装方針](#8-実装方針)
9. [開発ロードマップ](#9-開発ロードマップ)
10. [Event Schema](#10-event-schema)
11. [Permission / Fallback Spec](#11-permission--fallback-spec)
12. [MVP Definition](#12-mvp-definition)
13. [実装前ハードニング（v3）](#13-実装前ハードニングv3)
14. [IPC・単一セッション境界・event_id整合（v4）](#14-ipc単一セッション境界event_id整合v4)

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
> 連続オフセット計算は中間値（1.5dotなど）を生んでドットが崩れる。  
> 4枚の瞳座標セットを定義して切り替えるだけにする。

---

## 4. フレーム一覧（全14枚）

実測値：`charactor--01.png` 〜 `charactor--14.png` を Pillow でピクセル読み取り

### 視線フレーム（01〜05）

| フレーム | 瞳位置 | Swift座標 | 用途 |
|----------|--------|-----------|------|
| `01` | 中央 | `(sx+1, sy+1)` | 中央固定 / error / sleeping |
| `02` | 右下 | `pupil(sx+2, sy+2, 2, 6)` | **idle固定** / 通常待機 |
| `03` | 左下 | `pupil(sx, sy+2, 2, 6)` | 左方向 |
| `04` | 左上 | `pupil(sx, sy, 2, 6)` | 左上方向 |
| `05` | 右上 | `pupil(sx+2, sy, 2, 6)` | 思考傾向 |

```
frame02:      frame03:      frame04:      frame05:
y5: WWPP  →   y5: PPWW  →   y5: PPWW  →   y5: WWPP
y6: WWPP      y6: PPWW      y6: PPWW      y6: WWPP
y7: WWPP      y7: PPWW      y7: PPWW      y7: WWPP
```

### まばたきフレーム（06）

`open → half(60ms) → almost(60ms) → closed(06/90ms) → almost → half → open`  
次回まばたきまで 2.8〜5.5秒 ランダム待機

### エラー・完了フレーム（07〜14）

| フレーム | 用途 |
|----------|------|
| `07` | ERROR基点（控えめ×） |
| `08` | DONE驚き |
| `09〜14` | 完了くるくるアニメ / エラー上下シェイク |

**エラーアニメ**：`07 → 10 → 11 → 10 → 07`  
**完了アニメ**：`08 → 09 → 12 → 13 → 14 → 13 → 12`

---

## 5. アニメーション定義

### ジャンプ（DONEイベント）

NSStatusItem の Y オフセットにバウンスイージングを適用：  
`↑6px → ↑12px → ↑4px → 原点` の4ステップ  
完了後に吹き出し（NSWindow, borderless）が 3秒表示

---

## 6. マスコット状態一覧

> v1/v2 からの変更：
> - `idle` 視線を `tracking` から `fixed(.f02_rightDown)` に修正
> - `error` 視線を曖昧な "center" から `fixed(.f01_center)` に明示

| 状態（MascotPhase） | トリガー | 視線 | まばたき | 表情フレーム | 吹き出し |
|-------------------|---------|------|---------|------------|---------|
| `.idle` | 初期値 / done後 | `fixed(.f02, .mascotStateOverride)` | 通常 | frame02 | — |
| `.thinking` | session_start / tool_end成功後 | `tracking` or fallback | 通常 | frame05傾向 | 「考えてます...」 |
| `.working(tool)` | tool_start受信 | `tracking` or fallback | 通常 | frame02〜05（動的） | 「{tool} 実行中...」 |
| `.done(ms)` | session_done受信 | `fixed(.f02, .mascotStateOverride)` | 通常 | frame08→09→12→13→14 | `elapsed_ms>0`なら「完了！(3分42秒)」、`0`なら「完了！」 |
| `.error(tool,msg)` | tool_end is_error=true | `fixed(.f01, .mascotStateOverride)` | 停止 | frame07→10→11→10→07 | 「エラーが出ました…」 |
| `.sleeping` | 無操作タイマー（session==nil時のみ） | `fixed(.f01, .mascotStateOverride)` | 停止 | frame06 | — |

---

## 7. 技術アーキテクチャ

### データフロー

```
Claude Code
  └─ hooks (shell scripts in ~/.claude/hooks/)
       └─ Unix domain socket ($TMPDIR/clabotch.sock)
            └─ HookServer (Swift)
                 └─ LineBufferedEventDecoder   ← v4追加
                      └─ EventParser           (schema_version/event_id検証)
                           └─ EventDeduplicator ← v4追加
                                └─ StateMachine  (epoch guard + single-owner guard)
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
| `LineBufferedEventDecoder` | NDJSON行バッファリング |
| `EventParser` | JSON→ClabotchEnvelope変換 |
| `EventDeduplicator` | event_id短期重複除去（30秒/512件） |
| `StateMachine` | epoch guard + single-owner guard付き状態遷移 |
| `BubbleWindow: NSWindow` | 吹き出し表示 |

---

## 8. 実装方針

### ドット描画の核心原則

```swift
// ✅ 正しい：フレーム丸ごと切り替え
case .f02_rightDown: px(sx+2, sy+2, 2, 6)
case .f03_leftDown:  px(sx,   sy+2, 2, 6)
case .f04_leftUp:    px(sx,   sy,   2, 6)
case .f05_rightUp:   px(sx+2, sy,   2, 6)

// ❌ 禁止：連続オフセット計算（中間値でドットが崩れる）
// pupil.x += delta
```

### Retina対応

```swift
let dot = min(bounds.width / 22.0, bounds.height / 14.0)
// @2x → dot=2.0 が自動的に確定する
```

---

## 9. 開発ロードマップ

| Phase | 期間 | 内容 | リスク |
|-------|------|------|--------|
| **PoC** | 1日 | NSStatusItemにフレーム01を表示 + まばたき + Socket受信確認 | 低 |
| **v0.1** | 3日 | 視線追跡 + Hook受信 + StateMachine結合 | Warp AX互換性 |
| **v0.2** | 2日 | DONE/ERROR アニメ + ジャンプ + 吹き出し | 低 |
| **v0.3** | 3日 | 複数セッション並列 + 作業時間表示 | StateMachineリファクタ |
| **v1.0** | 4〜5日 | 設定画面 + LaunchAgent + Notarization + DMG | Apple Developer証明書 |

### Notarization 工数内訳（v1.0）

- Apple Developer Program（未登録なら ¥13,800/年）
- `xcrun notarytool submit` → Apple処理（30分〜2時間）
- `xcrun stapler staple` でDMGに結果を埋め込み
- Gatekeeper テスト（別端末推奨）

### NEXT（実装順 — v4確定版）

| 順序 | 作業 | 確認事項 |
|------|------|---------|
| 1 | **Hook 環境変数の実機確認** | `$SESSION_ID` `$TOOL_NAME` `$EXIT_CODE` `$TOOL_DURATION_MS` が実在するか |
| 2 | HookServer の NDJSON line buffer 実装 | §14.1参照 |
| 3 | EventParser の `schema_version` / `event_id` 検証 | §14.2参照 |
| 4 | EventDeduplicator 実装 | §14.2参照 |
| 5 | Single-session StateMachine guard 実装 | §14.3参照 |
| 6 | GazeController 実装 | Terminal / iTerm2 / WezTerm先行 |
| 7 | Warp AX調査 | 属性ダンプ後に対応可否を判断 |

---

## 10. Event Schema

### 10.1 設計方針

現行 hook は `tool_start` / `tool_end` / `done` の3種類しか送っていないが、  
UI は `idle` / `thinking` / `working` / `done` / `error` / `sleeping` の6状態を扱う。

#### 状態とイベントの対応表

| UI状態 | トリガーイベント | 補足 |
|--------|----------------|------|
| `idle` | 初期値 / `session_done` 後 | |
| `thinking` | `session_start` / `tool_end`（成功）後 | 推定状態（§13.1参照） |
| `working` | `tool_start` 受信 | |
| `done` | `session_done` 受信 | 完了アニメ後 → idle |
| `error` | `tool_end`（is_error=true）受信 | エラーアニメ後 → thinking |
| `sleeping` | クライアントサイドタイマー | session==nil時のみ（§13.5参照） |

#### `thinking` の実現方法

Claude Code には thinking hookが存在しない。  
→ `session_start` = **「最初の PreToolUse 時にセッションIDが新規かを確認して送るシェルラッパー方式」**

---

### 10.2 JSON スキーマ定義（v1）

#### 共通フィールド

| フィールド | 型 | 必須 | 説明 |
|------------|-----|------|------|
| `schema_version` | string | ✅ | 常に `"1"` |
| `event` | string enum | ✅ | 後述 |
| `session_id` | string | ✅ | `$SESSION_ID` |
| `event_id` | string (UUID v4) | ✅ | 重複除去用（30秒/512件保持） |
| `timestamp` | string (ISO8601 UTC) | ✅ | |

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
  "session_id":"sess_abc123", "event_id":"550e8400-e29b-41d4-a716-446655440000",
  "timestamp":"2026-03-10T09:00:00Z" }

{ "schema_version":"1", "event":"tool_start",
  "session_id":"sess_abc123", "event_id":"550e8400-e29b-41d4-a716-446655440001",
  "timestamp":"2026-03-10T09:00:05Z", "tool_name":"Write" }

{ "schema_version":"1", "event":"tool_end",
  "session_id":"sess_abc123", "event_id":"550e8400-e29b-41d4-a716-446655440002",
  "timestamp":"2026-03-10T09:00:06Z",
  "tool_name":"Write", "duration_ms":842, "is_error":false, "error_message":null }

{ "schema_version":"1", "event":"tool_end",
  "session_id":"sess_abc123", "event_id":"550e8400-e29b-41d4-a716-446655440003",
  "timestamp":"2026-03-10T09:00:07Z",
  "tool_name":"Bash", "duration_ms":201, "is_error":true, "error_message":"tool failed" }

{ "schema_version":"1", "event":"session_done",
  "session_id":"sess_abc123", "event_id":"550e8400-e29b-41d4-a716-446655440004",
  "timestamp":"2026-03-10T09:03:42Z", "elapsed_ms":222000 }
```

---

### 10.3 受信パイプライン（v4最終版）

受信処理は `LineBufferedEventDecoder` → `EventParser` → `EventDeduplicator` → `StateMachine` の4段構成。

```swift
// MARK: - 受信パイプライン統合

// ⚠️ スレッドセーフ注意：3コンポーネントはすべてメインスレッド専用
// HookServer がバックグラウンドスレッドで受信する場合は
// DispatchQueue.main.async で wrap してから呼ぶこと

let decoder      = LineBufferedEventDecoder()
let deduplicator = EventDeduplicator()

func handleIncomingData(_ chunk: Data) {
    for line in decoder.append(chunk) {
        guard let envelope = EventParser.parse(line) else { continue }
        guard deduplicator.shouldAccept(envelope.eventID) else { continue }
        stateMachine.handle(event: envelope.event)
    }
}
```

---

### 10.4 Hook シェル設定（v3最終版）

> **変更履歴（v1→v4）：**
> - `/tmp` → `$TMPDIR` に変更
> - `echo` → `printf` + `json_escape` に変更
> - `python3 uuid` → `uuidgen` に変更（macOS標準、依存ゼロ）
> - `session_start` をシェル側で送る仕組みを追加
> - `json_escape` でバックスラッシュ・引用符・改行をエスケープ

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
  s=${s//\\/\\\\}   # バックスラッシュを先にエスケープ
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

send_json() {
  [[ -S "$SOCK" ]] || return 0
  nc -U "$SOCK" >/dev/null 2>&1 || true   # best-effort：失敗しても継続
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

# tool_start を送る（改行末尾を必ず付ける = NDJSON仕様）
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
> `$SESSION_ID` / `$TOOL_NAME` / `$EXIT_CODE` / `$TOOL_DURATION_MS` の実際の変数名を  
> Claude Codeの実機でechoして確認する。存在しない変数はデフォルト値で代替。

---

## 11. Permission / Fallback Spec

### 11.1 アクセシビリティ権限の状態定義

```swift
enum GazePermissionStatus {
    case notDetermined   // 未確認（初回起動）
    case granted         // 許可済み → フル視線追跡
    case denied          // 拒否済み → 固定視線 frame02
}

private enum PermissionKeys {
    static let didRequestAccessibility = "didRequestAccessibility"
}
```

### 11.2 権限判定ロジック（v3修正版 — v2バグ修正済み）

> **v2バグ：** 旧 `checkPermission()` は初回 `notDetermined` を即 `denied` に潰していた。  
> OSの`AXIsProcessTrusted()`と`didRequestAccessibility`フラグを分離して3状態を管理する。

```swift
private func checkPermission() {
    let trusted    = AXIsProcessTrusted()
    let didRequest = UserDefaults.standard.bool(forKey: PermissionKeys.didRequestAccessibility)

    if trusted        { permissionStatus = .granted }
    else if didRequest { permissionStatus = .denied }
    else               { permissionStatus = .notDetermined }
}

func requestPermissionIfNeeded(completion: @escaping (GazePermissionStatus) -> Void) {
    checkPermission()
    guard permissionStatus == .notDetermined else { completion(permissionStatus); return }

    UserDefaults.standard.set(true, forKey: PermissionKeys.didRequestAccessibility)
    let _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true] as CFDictionary)

    // System Settings操作には数秒〜数分かかるため、
    // 1秒後チェックは初期確認のみ。継続的な確認は pollTimer（0.5秒）に委ねる
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
        self?.checkPermission()
        completion(self?.permissionStatus ?? .denied)
    }
}
```

### 11.3 視線モード定義

```swift
enum GazeMode: Equatable {
    case tracking
    case fixed(GazeFrame, reason: FixedGazeReason)
}

enum FixedGazeReason {
    case permissionDenied
    case permissionNotDetermined  // notDetermined中も自然な右下固定
    case terminalNotFound
    case terminalInOtherSpace
    case terminalMinimized
    case unsupportedTerminal
    case mascotStateOverride       // error/sleeping/idle など状態側が制御
}
```

### 11.4 各シナリオの振る舞い仕様

| シナリオ | GazeMode | 表示フレーム |
|---------|----------|------------|
| 権限許可 + ターミナル検出 | `.tracking` | frame02〜05（動的） |
| 権限許可 + ターミナル未検出 | `.fixed(.f01, .terminalNotFound)` | frame01 |
| 権限許可 + 別Space | `.fixed(.f01, .terminalInOtherSpace)` | frame01 |
| 権限許可 + 最小化 | `.fixed(.f01, .terminalMinimized)` | frame01 |
| 権限許可 + Warp | `.fixed(.f02, .unsupportedTerminal)` | frame02 |
| 権限 notDetermined | `.fixed(.f02, .permissionNotDetermined)` | frame02（自然） |
| 権限拒否 | `.fixed(.f02, .permissionDenied)` | frame02 |
| error 状態 | `.fixed(.f01, .mascotStateOverride)` | frame07→10→11 |
| sleeping 状態 | `.fixed(.f01, .mascotStateOverride)` | frame06 |

### 11.5 GazeController — 分類と AX 取得を分離した設計

```swift
final class GazeController {

    // MVP: 確認済み対応ターミナル
    private let supportedBundles: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "org.wezfurlong.wezterm"
    ]
    // AX属性ダンプ確認後に supportedBundles へ昇格させる候補
    private let tentativeBundles: Set<String> = [
        "dev.warp.desktop"
    ]

    // ① frontmost app を先に分類
    //    nil = 対応ターミナルが最前面 → AX取得へ進む
    //    非nil = 固定視線の理由が確定
    private func classifyFrontmostTerminal() -> FixedGazeReason? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return .terminalNotFound
        }
        let bundleID = frontApp.bundleIdentifier ?? ""
        if tentativeBundles.contains(bundleID) { return .unsupportedTerminal }
        guard supportedBundles.contains(bundleID) else { return .terminalNotFound }
        return nil
    }

    // ② window取得後の失敗理由を状況別に分ける
    //    window 0件               → .terminalMinimized
    //    position/size 取得不可   → .terminalInOtherSpace
    private func findTerminalCenter(pid: pid_t) -> (CGPoint?, FixedGazeReason?) {
        let axApp = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
            let windows = ref as? [AXUIElement], !windows.isEmpty
        else { return (nil, .terminalMinimized) }

        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(windows[0], kAXPositionAttribute as CFString, &posRef) == .success,
            AXUIElementCopyAttributeValue(windows[0], kAXSizeAttribute  as CFString, &sizeRef) == .success
        else { return (nil, .terminalInOtherSpace) }

        var pos  = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef  as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize,  &size)
        return (CGPoint(x: pos.x + size.width/2, y: pos.y + size.height/2), nil)
    }

    // ③ 視線方向の量子化（座標計算はこの関数のみ）
    private func quantize(from origin: CGPoint, to target: CGPoint) -> GazeFrame {
        let dx =  (target.x - origin.x)
        let dy = -(target.y - origin.y)   // macOS座標系: Y軸は下が正 → 反転
        switch (dx >= 0, dy >= 0) {
        case (true,  false): return .f02_rightDown
        case (false, false): return .f03_leftDown
        case (false, true):  return .f04_leftUp
        default:             return .f05_rightUp
        }
    }

    var statusItemCenterProvider: (() -> CGPoint?)?
    private(set) var gazeFrame: GazeFrame = .f02_rightDown
    private(set) var mode: GazeMode = .fixed(.f02_rightDown, reason: .terminalNotFound)
}
```

### 11.6 フォールバック優先順位

```
優先度（高 → 低）
1. mascotStateOverride  （error/sleeping/idle：状態側が制御）
2. permissionDenied / permissionNotDetermined → frame02 固定
3. tracking             （AX API リアルタイム追跡）
4. terminalInOtherSpace / terminalMinimized  → frame01 固定
5. terminalNotFound                          → frame01 固定
6. unsupportedTerminal                       → frame02 固定
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
- 「後で」 → `notDetermined` のまま起動。メニューバー右クリックから再表示可能

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

### 12.2 StateMachine — v3 epoch guard ＋ v4 single-owner guard 統合版

> **v4統合上の注意点：**
> v4パッチのStateMachine雛形にはv3のepoch guard（`transitionEpoch`, `pendingTransition`）が  
> 含まれていなかった。本仕様書では**両方を合成した版を正とする**。

```swift
// MARK: - StateMachine.swift  (v3 epoch guard + v4 single-owner guard)

final class StateMachine {

    private(set) var session: SessionState?
    private(set) var displayPhase: MascotPhase = .idle

    private var sleepTimer: Timer?
    private var pendingTransition: DispatchWorkItem?  // v3: キャンセル可能な遅延遷移
    private var transitionEpoch: UInt = 0             // v3: レース対策エポック番号

    private let sleepThreshold: TimeInterval = 300    // 5分

    // メインスレッド専用コールバック
    var onPhaseChanged: ((MascotPhase) -> Void)?
    /// foreign session_done 用 — フェーズ遷移はしない、吹き出しのみ
    var onEphemeralDone: ((Int) -> Void)?             // v4追加

    // MARK: - Public

    func handle(event: ClabotchEvent) {
        // 新イベントでpending transitionを必ずキャンセル（v3 epoch guard）
        transitionEpoch &+= 1
        pendingTransition?.cancel()
        pendingTransition = nil
        resetSleepTimer()

        switch event {

        // ── session_start ──────────────────────────────────────────────
        case .sessionStart(let sessionID):
            // v4 single-owner guard：active session と異なるIDは無視
            guard session == nil || session?.sessionID == sessionID else {
                debugLog("Ignoring foreign session_start: \(sessionID)")
                return
            }
            if session == nil {
                session = SessionState(
                    sessionID: sessionID,
                    phase: .thinking,
                    startedAt: Date(),
                    lastEventAt: Date()
                )
            }
            transition(to: .thinking)

        // ── tool_start ─────────────────────────────────────────────────
        case .toolStart(let sessionID, let toolName):
            guard isActiveSession(sessionID) else {
                debugLog("Ignoring foreign tool_start: \(sessionID)")
                return
            }
            session?.lastEventAt = Date()
            session?.phase = .working(toolName: toolName)
            transition(to: .working(toolName: toolName))

        // ── tool_end ───────────────────────────────────────────────────
        case .toolEnd(let sessionID, let toolName, _, let isError, let errorMessage):
            guard isActiveSession(sessionID) else {
                debugLog("Ignoring foreign tool_end: \(sessionID)")
                return
            }
            session?.lastEventAt = Date()
            if isError {
                let p = MascotPhase.error(toolName: toolName, message: errorMessage)
                session?.phase = p
                transition(to: p)
                // エラーアニメ終了後（2.5秒）→ thinking に自動遷移
                scheduleAutoTransition(to: .thinking, after: 2.5, expectedSessionID: sessionID)
            } else {
                session?.phase = .thinking
                transition(to: .thinking)
            }

        // ── session_done ───────────────────────────────────────────────
        case .sessionDone(let sessionID, let elapsedMs):
            if isActiveSession(sessionID) {
                // active session の正規完了
                session = nil
                transition(to: .done(elapsedMs: elapsedMs))
                scheduleAutoTransition(to: .idle, after: 4.0, expectedSessionID: nil)
            } else {
                // v4 foreign session_done：フェーズ遷移せず ephemeral 通知のみ
                debugLog("Foreign session_done -> ephemeral only: \(sessionID)")
                DispatchQueue.main.async { [weak self] in
                    self?.onEphemeralDone?(elapsedMs)
                }
            }

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
            guard self.transitionEpoch == epoch else { return }  // epochが変わっていたら無効
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
        guard session == nil else { return }  // active session中はタイマーを立てない
        sleepTimer = Timer.scheduledTimer(withTimeInterval: sleepThreshold, repeats: false) { [weak self] _ in
            guard self?.session == nil else { return }
            self?.transition(to: .sleeping)
        }
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        print("[Clabotch StateMachine] \(message)")
        #endif
    }
}
```

### 12.3 将来の複数セッション対応（v0.3 向けスケルトン）

```swift
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
| Hook受信 | Unix Socket（$TMPDIR使用）+ **NDJSON line buffer** |
| スキーマ検証 | `schema_version == "1"` の検証と破棄 |
| 重複除去 | `event_id` による短期除去（30秒/512件） |
| 状態遷移 | StateMachine（epoch guard + single-owner guard） |
| 完了アニメ | frame08→09→12→13→14、ジャンプ、吹き出し |
| エラーアニメ | frame07→10→11シェイク |
| sleeping | 5分タイマー（session==nil時のみ） |

#### 含めないもの（v0.3 以降）

| 機能 | 理由 |
|------|------|
| 複数セッションのフェーズ統合表示 | MultiSessionStateMachine 実装が必要 |
| foreign session の本格的な状態可視化 | MVP は onEphemeralDone の通知のみ |
| event replay / persistence | v1.0 以降 |
| 設定画面・LaunchAgent | v1.0 スコープ |
| Warp完全対応 | AX属性ダンプ確認後 |
| Apple公証 / DMG | v1.0 スコープ（工数 4〜5日） |

---

## 13. 実装前ハードニング（v3）

### 13.1 イベント観測の限界と MVP での扱い

| 項目 | MVP での扱い |
|------|--------------|
| `session_start` | 最初の PreToolUse 到達時に擬似生成するローカルイベント |
| ツール未使用セッション | `Stop` のみ観測可能。elapsed_ms は `0` |
| `thinking` | hook 起点の推定状態。厳密な開始時刻保証なし |
| 作業時間表示 | `elapsed_ms > 0` のときのみ吹き出しに表示 |

吹き出し文言ルール：`elapsed_ms > 0` → `完了！(3分42秒)` / `0` → `完了！`

### 13.2 Hook 送信の堅牢化（§10.4 補足）

1. `uuidgen` 使用（`python3` 依存除去）
2. `json_escape` helper でバックスラッシュ・引用符・改行をエスケープ
3. 送信は **best-effort**（ソケットがなければ黙って終了）
4. `error_message` 詳細取得は MVP 未対応（`"tool failed"` 固定）
5. JSON 末尾に必ず `\n` を付ける（**NDJSON仕様**）

### 13.3 権限状態の3値管理（§11.2 補足）

- `start()` では prompt を出さない
- オンボーディングの `[許可する]` 操作でのみ prompt を出す
- `notDetermined` の間は `permissionNotDetermined` 理由で frame02 固定
- `pollTimer`（0.5秒間隔）で `checkPermission()` を継続的に呼び、権限変更を検知する

### 13.4 Warp の `tentativeBundles` 分離（§11.5 補足）

- MVP の `supportedBundles` に Warp を含めない
- window取得失敗の理由は4種に分類（§11.5参照）

### 13.5 StateMachine レース対策（§12.2 補足）

- `transitionEpoch` で遅延遷移の無効化を保証
- `pendingTransition: DispatchWorkItem?` でキャンセル可能に
- `sleeping` は `session == nil` 時のみ発火

### 13.6 MVP の既知制約（明文化）

- ツール未使用セッションの経過時間は正確に測れない
- Warp は `.unsupportedTerminal` で固定視線に落とす
- `error_message` 詳細は v1.0 以降で改善余地あり
- `thinking` は厳密な開始時刻保証なし（推定状態）

---

## 14. IPC・単一セッション境界・event_id整合（v4）

### 14.1 Unix Socket の framing 仕様（NDJSON確定）

Unix stream socket では **1回の read が 1イベントになる保証はない**。  
Clabotch の IPC は **NDJSON（1行 = 1 JSONイベント）** を正式仕様とする。

| 項目 | 仕様 |
|------|------|
| transport | Unix domain socket |
| payload format | UTF-8 NDJSON |
| framing | `\n` 区切り |
| 1イベント | 1行に 1つの JSON object |
| 空行 | 無視 |
| 途中までの行 | 次回 read まで内部バッファに保持 |
| 不正 JSON 行 | その行だけ破棄して継続 |
| 推奨最大行長 | 8 KB（超えたら行ごと破棄） |

```swift
// MARK: - LineBufferedEventDecoder.swift
// ⚠️ メインスレッド専用（スレッドセーフではない）

import Foundation

final class LineBufferedEventDecoder {

    private var buffer = Data()
    private let maxLineBytes = 8 * 1024

    /// チャンクを受け取り、完成した行のみを返す
    func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []

        while let newlineRange = buffer.firstRange(of: Data([0x0A])) {
            let line = buffer.prefix(upTo: newlineRange.lowerBound)
            buffer.removeSubrange(..<newlineRange.upperBound)

            guard !line.isEmpty else { continue }
            guard line.count <= maxLineBytes else {
                // 8KB超の行は破棄
                continue
            }
            lines.append(Data(line))
        }

        // 不完全な巨大フラグメントがバッファに溜まり続けないようにクリア
        if buffer.count > maxLineBytes {
            buffer.removeAll(keepingCapacity: true)
        }

        return lines
    }
}
```

### 14.2 `schema_version` と `event_id` の実際の使用

#### EventParser（v4最終版 — ClabotchEnvelope を返す）

```swift
// MARK: - EventParser.swift

import Foundation

struct ClabotchEnvelope {
    let eventID: UUID
    let event: ClabotchEvent
}

struct EventParser {
    static func parse(_ data: Data) -> ClabotchEnvelope? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let schemaVersion = json["schema_version"] as? String,
            schemaVersion == "1",             // 未知バージョンは破棄（debug logに残す）
            let eventIDRaw = json["event_id"] as? String,
            let eventID = UUID(uuidString: eventIDRaw),
            let event = json["event"] as? String,
            let sessionID = json["session_id"] as? String
        else { return nil }

        let parsed: ClabotchEvent
        switch event {
        case "session_start":
            parsed = .sessionStart(sessionID: sessionID)
        case "tool_start":
            guard let toolName = json["tool_name"] as? String else { return nil }
            parsed = .toolStart(sessionID: sessionID, toolName: toolName)
        case "tool_end":
            guard
                let toolName   = json["tool_name"] as? String,
                let durationMs = json["duration_ms"] as? Int,
                let isError    = json["is_error"] as? Bool
            else { return nil }
            parsed = .toolEnd(
                sessionID: sessionID, toolName: toolName,
                durationMs: durationMs, isError: isError,
                errorMessage: json["error_message"] as? String
            )
        case "session_done":
            parsed = .sessionDone(
                sessionID: sessionID,
                elapsedMs: json["elapsed_ms"] as? Int ?? 0
            )
        default:
            parsed = .unknown(raw: json)
        }

        return ClabotchEnvelope(eventID: eventID, event: parsed)
    }
}
```

#### EventDeduplicator（30秒 / 512件の短期重複除去）

```swift
// MARK: - EventDeduplicator.swift
// ⚠️ メインスレッド専用（スレッドセーフではない）

import Foundation

final class EventDeduplicator {

    private struct Entry {
        let id: UUID
        let seenAt: Date
    }

    private var entries: [Entry] = []
    private let ttl: TimeInterval = 30    // 30秒
    private let maxEntries = 512

    func shouldAccept(_ id: UUID, now: Date = Date()) -> Bool {
        prune(now: now)

        if entries.contains(where: { $0.id == id }) {
            return false  // 重複 → 破棄
        }

        entries.append(.init(id: id, seenAt: now))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        return true
    }

    private func prune(now: Date) {
        entries.removeAll { now.timeIntervalSince($0.seenAt) > ttl }
    }
}
```

### 14.3 single-session MVP の防御線（v4 single-owner mode）

| 状況 | 挙動 |
|------|------|
| `session == nil` で `session_start` | 受理して active session にする |
| active session と同一 ID のイベント | 受理する |
| active session と異なる `session_start` | 無視（debug log のみ） |
| active session と異なる `tool_start` / `tool_end` | 無視（debug log のみ） |
| active session と異なる `session_done` | `onEphemeralDone` のみ呼ぶ（フェーズ遷移なし） |

#### `onEphemeralDone` の UI 仕様

- `displayPhase` は変更しない（active sessionの状態を壊さない）
- `elapsed_ms > 0` なら小さい吹き出しを 2秒表示する（例：「別セッション完了 (1分12秒)」）
- `elapsed_ms == 0` なら通知しない（ノイズになるため）
- 完了アニメ（ジャンプ・くるくる）は起こさない

> 実装は §12.2 の `StateMachine` に統合済み。

### 14.4 MVP スコープ追記

§12.4「含めるもの」に追加：
- HookServer の NDJSON line buffer
- `schema_version == "1"` 検証
- `event_id` 短期重複除去
- single-session guard
- ephemeral done 通知（`onEphemeralDone`）

§12.4「含めないもの」に追加：
- foreign session の本格的な状態可視化
- event replay / persistence

### 14.5 実装順（v4確定版）

| 順序 | 作業 | 確認事項 |
|------|------|---------|
| 1 | **Hook 環境変数の実機確認** | `$SESSION_ID` / `$TOOL_NAME` / `$EXIT_CODE` / `$TOOL_DURATION_MS` の実在確認 |
| 2 | HookServer の NDJSON line buffer | `LineBufferedEventDecoder` を先に完成させる |
| 3 | EventParser の schema_version / event_id 検証 | `ClabotchEnvelope` を返す形に変更 |
| 4 | EventDeduplicator 実装 | 30秒 / 512件 |
| 5 | Single-session StateMachine guard 実装 | epoch guard + single-owner guard の合成版 |
| 6 | GazeController 実装 | Terminal / iTerm2 / WezTerm 先行 |
| 7 | Warp AX調査 | AX属性ダンプ後に対応可否を判断して `tentativeBundles` から昇格 |

> HookServerとparserの境界を先に固めると、後段の状態遷移デバッグが大幅に楽になる。

---

## 成果物ファイル（v4時点）

| ファイル | 内容 |
|----------|------|
| `clabotch_design_doc_v4.md` | 本仕様書（v1〜v4統合） |
| `clabotch_sprites_v3.svg` | スプライトシート設計図 |
| `ClabotchEyeView_v3.swift` | 描画エンジン本体 |
| `~/.claude/hooks/clabotch_lib.sh` | hook共通helper（json_escape/uuidgen/send_json） |
| `~/.claude/hooks/clabotch_pre_tool.sh` | PreToolUse hook（session_start検知含む） |
| `~/.claude/hooks/clabotch_post_tool.sh` | PostToolUse hook |
| `~/.claude/hooks/clabotch_stop.sh` | Stop hook（elapsed_ms計算含む） |

---

## v1〜v4 変更履歴

| バージョン | 主な変更点 |
|-----------|-----------|
| v1 | 初期設計（既存設計書） |
| v2 | Event Schema / Permission Fallback / MVP Definition を追加（章10〜12） |
| v3 | Accessibility権限バグ修正 / epoch guard / Warp分離 / sleeping制限 / uuidgen |
| v4 | NDJSON framing / EventDeduplicator / single-owner guard / ephemeral done |

---

*Clabotch — MIT License — 2026 Nakata*  
*v4: 2026-03-10 — v4 IPC hardening patch 統合*
