# Clabotch（クラボッチ）設計仕様書 v6（最終版）

> Claude + bot + っち（たまごっちリスペクト）  
> macOSメニューバー常駐型 Claude Code マスコット  
>
> **本ドキュメント一本で実装を開始できる状態を目指す。**  
> v2〜v6 の全パッチを統合済み。過去のパッチファイルを参照する必要はない。

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
| `01` | 中央 | `(sx+1, sy+1)` | **中央固定 / error / sleeping** |
| `02` | 右下 | `pupil(sx+2, sy+2, 2, 6)` | **idle固定 / 通常待機** |
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

### まばたき（BlinkController）

`BlinkController` と `GazeController` は完全独立して動作する。  
まばたきタイマーはバックグラウンドで管理し、UI更新は `DispatchQueue.main.async` で行う。

### ジャンプ（DONEイベント）

NSStatusItem の Y オフセットにバウンスイージングを適用：  
`↑6px → ↑12px → ↑4px → 原点` の4ステップ  
完了後に吹き出し（NSWindow, borderless）が 3秒表示

---

## 6. マスコット状態一覧

> **v1/v2からの変更点：**
> - `idle` 視線を `tracking` → `fixed(.f02_rightDown)` に修正（セッションなし時はAX不要）
> - `error` 視線を曖昧な "center" → `fixed(.f01_center)` に明示

| 状態（MascotPhase） | トリガー | 視線 | まばたき | 表情フレーム | 吹き出し |
|-------------------|---------|------|---------|------------|---------|
| `.idle` | 初期値 / done後 | `fixed(.f02, .mascotStateOverride)` | 通常 | frame02 | — |
| `.thinking` | session_start / tool_end成功後 | `tracking` or fallback | 通常 | frame05傾向 | 「考えてます...」 |
| `.working(tool)` | tool_start受信 | `tracking` or fallback | 通常 | frame02〜05（動的） | 「{tool} 実行中...」 |
| `.done(ms)` | session_done（active） | `fixed(.f02, .mascotStateOverride)` | 通常 | frame08→09→12→13→14 | `ms>0` → 「完了！(3分42秒)」<br>`ms==0` → 「完了！」 |
| `.error(tool,msg)` | tool_end is_error=true | `fixed(.f01, .mascotStateOverride)` | 停止 | frame07→10→11→10→07 | 「エラーが出ました…」 |
| `.sleeping` | 無操作タイマー（session==nil時のみ） | `fixed(.f01, .mascotStateOverride)` | 停止 | frame06 | — |

### 吹き出し文言規約（全パターン）

| ケース | 表示 |
|--------|------|
| active `session_done(ms > 0)` | 「完了！(3分42秒)」 |
| active `session_done(ms == 0)` | 「完了！」 |
| foreign `session_done(ms > 0)` | 「別セッション完了 (1分12秒)」（ephemeral 2秒） |
| foreign `session_done(ms == 0)` | **無通知（silent drop）** |

---

## 7. 技術アーキテクチャ

### データフロー

```
Claude Code
  └─ hooks (shell scripts in ~/.claude/hooks/)
       └─ Unix domain socket ($TMPDIR/clabotch.sock)
            └─ HookServer.accept() ループ
                 └─ [接続ごと]
                      ├─ connectionQueue (serial)
                      │    ├─ LineBufferedEventDecoder  ← 接続ごとに生成
                      │    └─ EventParser              (pure function)
                      └─ DispatchQueue.main
                           ├─ EventDeduplicator        (main only)
                           └─ StateMachine             (main only)
                                ├─ ClabotchEyeView（描画）
                                ├─ BlinkController（まばたき）
                                ├─ GazeController（視線）
                                └─ BubbleWindow（吹き出し）
```

### コンポーネント別スレッド所有権

| コンポーネント | スレッド所有権 | 共有 |
|----------------|--------------|------|
| `LineBufferedEventDecoder` | 接続ごとの serial queue 専用 | ❌ 共有禁止 |
| `EventParser` | pure function（任意スレッドで実行可） | ✅ |
| `EventDeduplicator` | **メインスレッド専用** | ✅ グローバル1個 |
| `StateMachine` | **メインスレッド専用** | ✅ グローバル1個 |
| UI callbacks | **メインスレッド専用** | — |

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

### NEXT（実装順 — v6確定版）

| 順序 | 作業 | 確認事項 |
|------|------|---------|
| 1 | **Hook 環境変数の実機確認** | `$SESSION_ID` `$TOOL_NAME` `$EXIT_CODE` `$TOOL_DURATION_MS` が実在するか |
| 2 | HookServer の NDJSON line buffer 実装 | §14.1 参照 |
| 3 | EventParser の schema_version / event_id 検証 | §14.2 参照 |
| 4 | EventDeduplicator 実装 | §14.2 参照 |
| 5 | Single-session StateMachine guard 実装 | §12.2 参照 |
| 6 | GazeController 実装 | Terminal / iTerm2 / WezTerm 先行 |
| 7 | Warp AX調査 | AX属性ダンプ後に対応可否を判断 |

---

## 10. Event Schema

### 10.1 設計方針

#### 状態とイベントの対応表

| UI状態 | トリガーイベント |
|--------|----------------|
| `idle` | 初期値 / `session_done` 後 |
| `thinking` | `session_start` / `tool_end`（成功）後 |
| `working` | `tool_start` 受信 |
| `done` | `session_done` 受信（active session） |
| `error` | `tool_end`（is_error=true）受信 |
| `sleeping` | クライアントサイドタイマー（session==nil時のみ） |

#### `thinking` の実現方法

Claude Code には thinking hookが存在しない。  
`session_start` = **「最初の PreToolUse 時にセッションIDが新規かを確認して送るシェルラッパー方式」**（§10.4参照）

---

### 10.2 JSON スキーマ定義（v1）

#### 共通フィールド

| フィールド | 型 | 必須 | 説明 |
|------------|-----|------|------|
| `schema_version` | string | ✅ | 常に `"1"` |
| `event` | string enum | ✅ | 後述 |
| `session_id` | string | ✅ | `$SESSION_ID` |
| `event_id` | string (UUID v4) | ✅ | 重複除去用（30秒/512件） |
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

### 10.3 受信パイプライン（v6最終版）

```
HookServer.accept() ループ
    ↓ 接続ごとに:
    [1] LineBufferedEventDecoder.append(chunk)    ← 接続ごとの serial queue
    [2] EventParser.parse(line) × N               ← pure function、同 queue
    [3] DispatchQueue.main.async {
          EventDeduplicator.shouldAccept(id)      ← main thread
          StateMachine.handle(event)              ← main thread
        }
```

```swift
// MARK: - 受信パイプライン（v6最終版）
// ルール:
//   LineBufferedEventDecoder → 接続ごとに生成（共有禁止）
//   EventParser              → pure function（任意スレッドで実行可）
//   EventDeduplicator        → メインスレッド専用（グローバル1個）
//   StateMachine             → メインスレッド専用（グローバル1個）

let deduplicator = EventDeduplicator()  // グローバル（main only）
// stateMachine は AppDelegate / Coordinator から注入

func handleNewConnection(connection: UnixSocketConnection) {
    let decoder = LineBufferedEventDecoder()                   // 接続ごとに生成
    let connectionQueue = DispatchQueue(
        label: "com.clabotch.socket.\(UUID().uuidString)"     // 接続専用 serial queue
    )

    connection.onData = { chunk in
        connectionQueue.async {
            // [1][2] framing と parse は接続 queue 上で実行
            let envelopes = decoder.append(chunk).compactMap(EventParser.parse)

            // [3] dedup と状態遷移はまとめて main thread へ
            DispatchQueue.main.async {
                for envelope in envelopes {
                    guard deduplicator.shouldAccept(envelope.eventID) else { continue }
                    stateMachine.handle(event: envelope.event)
                }
            }
        }
    }
}
```

---

### 10.4 Hook シェル設定（v6最終版）

#### 共通 helper（`~/.claude/hooks/clabotch_lib.sh`）

```bash
#!/usr/bin/env bash
# v6: send_json に -w 1 追加（BSD nc idle timeout）

SOCK="${TMPDIR}clabotch.sock"
SESSION_REGISTRY="${TMPDIR}clabotch_sessions"

generate_uuid() {
  uuidgen | tr '[:upper:]' '[:lower:]'
}

json_escape() {
  local s="$1"
  s=${s//\\/\\\\}    # バックスラッシュを先にエスケープ
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

# best-effort 送信
# - ソケットがなければ何もしない
# - `-w 1` は BSD nc の idle timeout を 1 秒に設定する
# - peer 不調時のぶら下がり時間を減らすための軽減策
# - 「厳密な 1 秒以内で返ること」の仕様保証はしない
# - strict な hard timeout が必要になった場合は nc をやめて専用 sender に置き換える
send_json() {
  [[ -S "$SOCK" ]] || return 0
  nc -w 1 -U "$SOCK" >/dev/null 2>&1 || true
}
```

#### `~/.claude/hooks/clabotch_pre_tool.sh`

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/clabotch_lib.sh"

SESSION_START_FILE="${SESSION_REGISTRY}/${SESSION_ID}"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# 新規セッション検知 → session_start を送る
mkdir -p "$SESSION_REGISTRY"
if [[ ! -f "$SESSION_START_FILE" ]]; then
  date +%s > "$SESSION_START_FILE"
  printf '{"schema_version":"1","event":"session_start","session_id":"%s","event_id":"%s","timestamp":"%s"}\n' \
    "$SESSION_ID" "$(generate_uuid)" "$NOW" | send_json
fi

# tool_start を送る（\n 末尾必須 = NDJSON仕様）
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

> ⚠️ **実装前に必ず確認（§9 NEXT の順序1）：**  
> `$SESSION_ID` / `$TOOL_NAME` / `$EXIT_CODE` / `$TOOL_DURATION_MS` の実在確認。  
> 存在しない変数はデフォルト値で代替。

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

### 11.2 権限判定ロジック

> **v2バグ修正：** 旧実装は初回 `notDetermined` を即 `denied` に潰していた。

```swift
private func checkPermission() {
    let trusted    = AXIsProcessTrusted()
    let didRequest = UserDefaults.standard.bool(forKey: PermissionKeys.didRequestAccessibility)

    if trusted         { permissionStatus = .granted }
    else if didRequest { permissionStatus = .denied }
    else               { permissionStatus = .notDetermined }
}

func requestPermissionIfNeeded(completion: @escaping (GazePermissionStatus) -> Void) {
    checkPermission()
    guard permissionStatus == .notDetermined else { completion(permissionStatus); return }

    UserDefaults.standard.set(true, forKey: PermissionKeys.didRequestAccessibility)
    let _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true] as CFDictionary)

    // 1秒後初期チェック。System Settings操作完了の継続検知は pollTimer（0.5秒）に委ねる
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
    case permissionNotDetermined
    case terminalNotFound
    case terminalInOtherSpace
    case terminalMinimized
    case unsupportedTerminal
    case mascotStateOverride
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

    // ① frontmost app を先に分類（AX呼び出し前に理由を確定）
    //    nil = 対応ターミナルが最前面 → AX取得へ進む
    private func classifyFrontmostTerminal() -> FixedGazeReason? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return .terminalNotFound
        }
        let bundleID = frontApp.bundleIdentifier ?? ""
        if tentativeBundles.contains(bundleID) { return .unsupportedTerminal }
        guard supportedBundles.contains(bundleID) else { return .terminalNotFound }
        return nil
    }

    // ② window取得後の失敗理由を状況別に分類
    //    window 0件             → .terminalMinimized
    //    position/size 取得不可 → .terminalInOtherSpace
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
            AXUIElementCopyAttributeValue(windows[0], kAXSizeAttribute     as CFString, &sizeRef) == .success
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
        let dy = -(target.y - origin.y)   // macOS座標系: Y軸下が正 → 反転
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
1. mascotStateOverride  （error/sleeping/idle）
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
│  Claude Code の作業をメニューバーで見守ります。   │
│                                              │
│  視線追跡機能を使うには                         │
│  アクセシビリティの許可が必要です。               │
│  ※ 許可しなくても機能の95%は動作します。          │
│                                              │
│        [後で]            [許可する]            │
└──────────────────────────────────────────────┘
```

---

## 12. MVP Definition

### 12.1 状態定義

```swift
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

### 12.2 StateMachine（v6最終版）

> **v3〜v6 の全修正を統合：**
> - v3: epoch guard（`transitionEpoch`, `pendingTransition`）
> - v3: sleeping はセッション非存在時のみ発火
> - v4: foreign session_done → ephemeral 通知のみ
> - v5: ownership-first guard（`isOwned()` / `handleForeign()`を分離）
> - v6: foreign `elapsed_ms == 0` → silent drop

```swift
// MARK: - StateMachine.swift（v6最終版）
// 変更の核心: isOwned() で ownership を副作用ゼロで先に判定。
// 受理確定後のみ epoch/cancel/sleepReset を適用する。

final class StateMachine {

    private(set) var session: SessionState?
    private(set) var displayPhase: MascotPhase = .idle

    private var sleepTimer: Timer?
    private var pendingTransition: DispatchWorkItem?  // キャンセル可能な遅延遷移
    private var transitionEpoch: UInt = 0             // レース対策エポック番号
    private let sleepThreshold: TimeInterval = 300    // 5分

    var onPhaseChanged: ((MascotPhase) -> Void)?
    var onEphemeralDone: ((Int) -> Void)?             // foreign session_done（ms > 0 のみ）

    // MARK: - Public

    func handle(event: ClabotchEvent) {

        // ── Step 1: ownership 判定（副作用ゼロ）──────────────────────
        // foreign event は handleForeign に転送して即 return。
        // epoch / cancel / sleepTimer には一切触れない。
        guard isOwned(event) else {
            handleForeign(event)
            return
        }

        // ── Step 2: 受理確定後のみ副作用を適用 ──────────────────────
        transitionEpoch &+= 1
        pendingTransition?.cancel()
        pendingTransition = nil
        resetSleepTimer()

        // ── Step 3: 状態遷移（ownership 確定済み）───────────────────
        switch event {

        case .sessionStart(let sessionID):
            if session == nil {
                session = SessionState(
                    sessionID: sessionID,
                    phase: .thinking,
                    startedAt: Date(),
                    lastEventAt: Date()
                )
            }
            transition(to: .thinking)

        case .toolStart(_, let toolName):
            session?.lastEventAt = Date()
            session?.phase = .working(toolName: toolName)
            transition(to: .working(toolName: toolName))

        case .toolEnd(let sessionID, let toolName, _, let isError, let errorMessage):
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

        case .sessionDone(_, let elapsedMs):
            session = nil
            transition(to: .done(elapsedMs: elapsedMs))
            // 完了アニメ終了後（4秒）→ idle に自動遷移
            scheduleAutoTransition(to: .idle, after: 4.0, expectedSessionID: nil)

        case .unknown:
            break
        }
    }

    // MARK: - Ownership

    /// イベントがこの StateMachine の active session に属するか判定する（副作用ゼロ）
    private func isOwned(_ event: ClabotchEvent) -> Bool {
        switch event {
        case .sessionStart(let id):
            return session == nil || session?.sessionID == id
        case .toolStart(let id, _),
             .toolEnd(let id, _, _, _, _),
             .sessionDone(let id, _):
            return isActiveSession(id)
        case .unknown:
            return false
        }
    }

    /// foreign イベントの処理（フェーズ遷移・epoch・sleepTimer すべて触らない）
    private func handleForeign(_ event: ClabotchEvent) {
        switch event {
        case .sessionDone(let id, let elapsedMs):
            // foreign completion は elapsed_ms > 0 の場合のみ ephemeral 通知する
            // elapsed_ms == 0 は silent drop（active session の表示を優先）
            debugLog("Foreign session_done -> ephemeral only: \(id)")
            guard elapsedMs > 0 else { return }
            DispatchQueue.main.async { [weak self] in
                self?.onEphemeralDone?(elapsedMs)
            }
        case .sessionStart(let id):
            debugLog("Ignoring foreign session_start: \(id)")
        case .toolStart(let id, _):
            debugLog("Ignoring foreign tool_start: \(id)")
        case .toolEnd(let id, _, _, _, _):
            debugLog("Ignoring foreign tool_end: \(id)")
        case .unknown:
            break
        }
    }

    // MARK: - Private helpers

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
            guard self.transitionEpoch == epoch else { return }  // 古い遷移は無効
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
        sleepTimer = Timer.scheduledTimer(
            withTimeInterval: sleepThreshold, repeats: false
        ) { [weak self] _ in
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
| フレーム描画 | frame01〜14（全フレーム） |
| まばたき | BlinkController、2.8〜5.5秒ランダム |
| 視線追跡 | GazeController（AX API / fallback） |
| Hook受信 | Unix Socket（$TMPDIR）+ NDJSON line buffer |
| スキーマ検証 | `schema_version == "1"` の検証と破棄 |
| 重複除去 | `event_id` による短期除去（30秒/512件） |
| 状態遷移 | StateMachine（epoch guard + ownership-first guard） |
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

### 13.2 Hook 送信の堅牢化

1. `uuidgen` 使用（`python3` 依存除去）
2. `json_escape` helper でエスケープ
3. 送信は **best-effort**（ソケットがなければ黙って終了）
4. JSON 末尾に必ず `\n` を付ける（NDJSON仕様）
5. `nc -w 1` で idle timeout 1秒の stall 軽減策

### 13.3 権限状態の3値管理

- `start()` では prompt を出さない
- オンボーディングの `[許可する]` でのみ prompt を出す
- `notDetermined` の間は `permissionNotDetermined` 理由で frame02 固定
- `pollTimer`（0.5秒間隔）で継続的に `checkPermission()` を呼び権限変更を検知する

### 13.4 Warp の `tentativeBundles` 分離

- MVP の `supportedBundles` に Warp を含めない
- window取得失敗の理由は4種に分類（§11.5参照）

### 13.5 StateMachine レース対策

- `transitionEpoch` で遅延遷移の無効化を保証
- `pendingTransition: DispatchWorkItem?` でキャンセル可能に
- `sleeping` は `session == nil` 時のみ発火

### 13.6 MVP の既知制約

- ツール未使用セッションの経過時間は正確に測れない
- Warp は `.unsupportedTerminal` で固定視線に落とす
- `error_message` 詳細は v1.0 以降で改善余地あり
- `thinking` は厳密な開始時刻保証なし（推定状態）

---

## 14. IPC・単一セッション境界・event_id整合（v4）

### 14.1 Unix Socket の framing 仕様（NDJSON確定）

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
// ⚠️ 接続ごとに生成。複数接続で共有禁止。

final class LineBufferedEventDecoder {

    private var buffer = Data()
    private let maxLineBytes = 8 * 1024

    func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []

        while let newlineRange = buffer.firstRange(of: Data([0x0A])) {
            let line = buffer.prefix(upTo: newlineRange.lowerBound)
            buffer.removeSubrange(..<newlineRange.upperBound)
            guard !line.isEmpty else { continue }
            guard line.count <= maxLineBytes else { continue }
            lines.append(Data(line))
        }

        if buffer.count > maxLineBytes {
            buffer.removeAll(keepingCapacity: true)
        }

        return lines
    }
}
```

### 14.2 EventParser と EventDeduplicator

```swift
// MARK: - EventParser.swift
// pure function（任意スレッドで実行可）

struct ClabotchEnvelope {
    let eventID: UUID
    let event: ClabotchEvent
}

struct EventParser {
    static func parse(_ data: Data) -> ClabotchEnvelope? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let schemaVersion = json["schema_version"] as? String,
            schemaVersion == "1",
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

```swift
// MARK: - EventDeduplicator.swift
// ⚠️ メインスレッド専用（グローバル1個）

final class EventDeduplicator {

    private struct Entry { let id: UUID; let seenAt: Date }
    private var entries: [Entry] = []
    private let ttl: TimeInterval = 30
    private let maxEntries = 512

    func shouldAccept(_ id: UUID, now: Date = Date()) -> Bool {
        prune(now: now)
        if entries.contains(where: { $0.id == id }) { return false }
        entries.append(.init(id: id, seenAt: now))
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
        return true
    }

    private func prune(now: Date) {
        entries.removeAll { now.timeIntervalSince($0.seenAt) > ttl }
    }
}
```

### 14.3 single-session MVP の防御線

| 状況 | 挙動 |
|------|------|
| `session == nil` で `session_start` | 受理して active session にする |
| active session と同一 ID のイベント | 受理する |
| active session と異なる `session_start` / `tool_*` | 無視（debug log のみ） |
| active session と異なる `session_done(ms > 0)` | `onEphemeralDone` のみ（2秒吹き出し） |
| active session と異なる `session_done(ms == 0)` | **silent drop** |

---

## v1〜v6 変更履歴

| バージョン | 主な変更点 |
|-----------|-----------|
| v1 | 初期設計 |
| v2 | Event Schema / Permission Fallback / MVP Definition 追加（章10〜12） |
| v3 | Accessibility権限バグ修正 / epoch guard / Warp分離 / sleeping制限 / uuidgen |
| v4 | NDJSON framing / EventDeduplicator / single-owner guard / ephemeral done |
| v5 | decoderスコープ修正 / StateMachine ownership-first guard / nc -w 1 追加 |
| v6 | スレッド境界明示（connectionQueue→main） / nc timeout 表現修正 / elapsed_ms==0 silent drop 確定 |

---

## 成果物ファイル

| ファイル | 内容 |
|----------|------|
| `clabotch_design_doc_v6.md` | 本仕様書（v1〜v6統合、実装開始可能） |
| `clabotch_sprites_v3.svg` | スプライトシート設計図 |
| `ClabotchEyeView_v3.swift` | 描画エンジン本体 |
| `~/.claude/hooks/clabotch_lib.sh` | hook共通helper |
| `~/.claude/hooks/clabotch_pre_tool.sh` | PreToolUse hook |
| `~/.claude/hooks/clabotch_post_tool.sh` | PostToolUse hook |
| `~/.claude/hooks/clabotch_stop.sh` | Stop hook |

---

*Clabotch — MIT License — 2026 Nakata*  
*v6: 2026-03-10 — v2〜v6 全パッチ統合・実装開始可能版*
