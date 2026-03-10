# Clabotch 設計仕様書 — 追記3章

> 前回レビュー指摘事項の反映 + 別レビュー（Codex）指摘事項への対応  
> 本ドキュメントは `clabotch_design_doc.md` の **章10〜12** として追記する

---

## 目次（追記分）

10. [Event Schema](#event-schema)
11. [Permission / Fallback Spec](#permission--fallback-spec)
12. [MVP Definition](#mvp-definition)

---

## 10. Event Schema

### 10.1 設計方針

現行 hook は `tool_start` / `tool_end` / `done` の3種類しか送っていないが、  
UI は `idle` / `thinking` / `working` / `done` / `error` / `sleeping` の6状態を扱う。  
このギャップを「**hook側で状態を増やす**」ことで解消する。

#### 状態とイベントの対応表

| UI状態 | トリガーイベント | 補足 |
|--------|----------------|------|
| `idle` | 初期値 / `session_done` 受信後 | appが起動したらidle |
| `thinking` | `session_start` 受信 / `tool_end`（成功）受信後 | LLMが考えている期間 |
| `working` | `tool_start` 受信 | ツール実行中 |
| `done` | `session_done` 受信 | 完了アニメ後 → idle に自動遷移 |
| `error` | `tool_end`（is_error=true）受信 | エラーアニメ後 → thinking に遷移 |
| `sleeping` | クライアントサイドタイマー（無操作 N 秒） | hookなし。StateMachine内で管理 |

**`thinking` の実現方法 について**  
Claude Code には `thinking` hookが存在しない。  
→ `session_start` イベントを「最初の `PreToolUse` が来たタイミングでセッションIDが新規かを確認して送る」  
 シェルラッパー方式で実装する（後述 §10.4）。

---

### 10.2 JSON スキーマ定義（v1）

#### 共通フィールド

| フィールド | 型 | 必須 | 説明 |
|------------|-----|------|------|
| `schema_version` | string | ✅ | 常に `"1"` |
| `event` | string enum | ✅ | 後述 |
| `session_id` | string | ✅ | Claude Code の `$SESSION_ID` |
| `event_id` | string | ✅ | 送信側で生成する UUID v4（重複除去用） |
| `timestamp` | string (ISO8601) | ✅ | `date -u +%Y-%m-%dT%H:%M:%SZ` |

#### イベント別フィールド

```
event: "session_start"
─────────────────────
（共通フィールドのみ）


event: "tool_start"
────────────────────
tool_name : string  // $TOOL_NAME そのまま


event: "tool_end"
──────────────────
tool_name  : string
duration_ms: number  // tool実行時間
is_error   : bool
error_message : string | null  // is_error=true のときのみ


event: "session_done"
──────────────────────
elapsed_ms : number  // セッション開始からの経過時間
```

#### サンプル JSON（全種類）

```json
// session_start
{
  "schema_version": "1",
  "event": "session_start",
  "session_id": "sess_abc123",
  "event_id": "550e8400-e29b-41d4-a716-446655440000",
  "timestamp": "2026-03-10T09:00:00Z"
}

// tool_start
{
  "schema_version": "1",
  "event": "tool_start",
  "session_id": "sess_abc123",
  "event_id": "550e8400-e29b-41d4-a716-446655440001",
  "timestamp": "2026-03-10T09:00:05Z",
  "tool_name": "Write"
}

// tool_end（成功）
{
  "schema_version": "1",
  "event": "tool_end",
  "session_id": "sess_abc123",
  "event_id": "550e8400-e29b-41d4-a716-446655440002",
  "timestamp": "2026-03-10T09:00:06Z",
  "tool_name": "Write",
  "duration_ms": 842,
  "is_error": false,
  "error_message": null
}

// tool_end（エラー）
{
  "schema_version": "1",
  "event": "tool_end",
  "session_id": "sess_abc123",
  "event_id": "550e8400-e29b-41d4-a716-446655440003",
  "timestamp": "2026-03-10T09:00:07Z",
  "tool_name": "Bash",
  "duration_ms": 201,
  "is_error": true,
  "error_message": "command not found: pyhton3"
}

// session_done
{
  "schema_version": "1",
  "event": "session_done",
  "session_id": "sess_abc123",
  "event_id": "550e8400-e29b-41d4-a716-446655440004",
  "timestamp": "2026-03-10T09:03:42Z",
  "elapsed_ms": 222000
}
```

---

### 10.3 受信側パーサー（Swift 雛形）

```swift
// MARK: - ClabotchEvent.swift

import Foundation

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
        else { return nil }

        switch event {
        case "session_start":
            return .sessionStart(sessionID: sessionID)

        case "tool_start":
            guard let toolName = json["tool_name"] as? String else { return nil }
            return .toolStart(sessionID: sessionID, toolName: toolName)

        case "tool_end":
            guard
                let toolName = json["tool_name"] as? String,
                let durationMs = json["duration_ms"] as? Int,
                let isError = json["is_error"] as? Bool
            else { return nil }
            let errorMessage = json["error_message"] as? String
            return .toolEnd(
                sessionID: sessionID,
                toolName: toolName,
                durationMs: durationMs,
                isError: isError,
                errorMessage: errorMessage
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

### 10.4 Hook シェル設定（修正版）

> **変更点：**  
> - `/tmp` 固定を廃止 → `$TMPDIR` 使用  
> - `echo` → `printf` で JSON 安全性を確保  
> - `session_start` をシェル側で送る仕組みを追加  
> - `elapsed_ms` を `session_done` に含める

#### `~/.claude/settings.json` hooks セクション

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "command": "~/.claude/hooks/clabotch_pre_tool.sh"
      }
    ],
    "PostToolUse": [
      {
        "command": "~/.claude/hooks/clabotch_post_tool.sh"
      }
    ],
    "Stop": [
      {
        "command": "~/.claude/hooks/clabotch_stop.sh"
      }
    ]
  }
}
```

#### `~/.claude/hooks/clabotch_pre_tool.sh`

```bash
#!/usr/bin/env bash
# Clabotch PreToolUse hook
# 環境変数: SESSION_ID, TOOL_NAME

SOCK="${TMPDIR}clabotch.sock"
SESSION_REGISTRY="${TMPDIR}clabotch_sessions"
SESSION_START_FILE="${SESSION_REGISTRY}/${SESSION_ID}"

# ソケットが存在しない場合はサイレントに終了
[[ -S "$SOCK" ]] || exit 0

generate_uuid() {
  python3 -c "import uuid; print(uuid.uuid4())"
}

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EPOCH=$(date +%s)

# 新規セッション検知 → session_start を送る
mkdir -p "$SESSION_REGISTRY"
if [[ ! -f "$SESSION_START_FILE" ]]; then
  echo "$EPOCH" > "$SESSION_START_FILE"
  printf '{"schema_version":"1","event":"session_start","session_id":"%s","event_id":"%s","timestamp":"%s"}\n' \
    "$SESSION_ID" "$(generate_uuid)" "$NOW" | nc -U "$SOCK"
fi

# tool_start を送る
printf '{"schema_version":"1","event":"tool_start","session_id":"%s","event_id":"%s","timestamp":"%s","tool_name":"%s"}\n' \
  "$SESSION_ID" "$(generate_uuid)" "$NOW" "$TOOL_NAME" | nc -U "$SOCK"
```

#### `~/.claude/hooks/clabotch_post_tool.sh`

```bash
#!/usr/bin/env bash
# Clabotch PostToolUse hook
# 環境変数: SESSION_ID, TOOL_NAME, TOOL_DURATION_MS, EXIT_CODE

SOCK="${TMPDIR}clabotch.sock"
[[ -S "$SOCK" ]] || exit 0

generate_uuid() { python3 -c "import uuid; print(uuid.uuid4())"; }

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
DURATION="${TOOL_DURATION_MS:-0}"

# EXIT_CODE が 0 以外 or STDERR に内容があればエラー扱い
IS_ERROR="false"
ERROR_MSG="null"
if [[ "${EXIT_CODE:-0}" != "0" ]]; then
  IS_ERROR="true"
  # error_message はシェルでは取得困難なため空文字
  ERROR_MSG='""'
fi

printf '{"schema_version":"1","event":"tool_end","session_id":"%s","event_id":"%s","timestamp":"%s","tool_name":"%s","duration_ms":%s,"is_error":%s,"error_message":%s}\n' \
  "$SESSION_ID" "$(generate_uuid)" "$NOW" "$TOOL_NAME" "$DURATION" "$IS_ERROR" "$ERROR_MSG" \
  | nc -U "$SOCK"
```

#### `~/.claude/hooks/clabotch_stop.sh`

```bash
#!/usr/bin/env bash
# Clabotch Stop hook

SOCK="${TMPDIR}clabotch.sock"
SESSION_REGISTRY="${TMPDIR}clabotch_sessions"
SESSION_START_FILE="${SESSION_REGISTRY}/${SESSION_ID}"
[[ -S "$SOCK" ]] || exit 0

generate_uuid() { python3 -c "import uuid; print(uuid.uuid4())"; }

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# elapsed_ms を計算
ELAPSED_MS=0
if [[ -f "$SESSION_START_FILE" ]]; then
  START_EPOCH=$(cat "$SESSION_START_FILE")
  NOW_EPOCH=$(date +%s)
  ELAPSED_MS=$(( (NOW_EPOCH - START_EPOCH) * 1000 ))
  rm -f "$SESSION_START_FILE"
fi

printf '{"schema_version":"1","event":"session_done","session_id":"%s","event_id":"%s","timestamp":"%s","elapsed_ms":%d}\n' \
  "$SESSION_ID" "$(generate_uuid)" "$NOW" "$ELAPSED_MS" | nc -U "$SOCK"
```

> **Note:** `$TOOL_DURATION_MS` / `$EXIT_CODE` は Claude Code が実際に提供する環境変数を確認の上、  
> 利用できない場合は `duration_ms: 0` / `is_error: false` にフォールバックして受信側で判定する。

---

## 11. Permission / Fallback Spec

### 11.1 アクセシビリティ権限の状態遷移

```
┌──────────────────────────────────────────────────────┐
│  アプリ初回起動                                        │
│        ↓                                             │
│  権限チェック                                          │
│    ├─ 未リクエスト → オンボーディング表示 → 権限リクエスト │
│    ├─ 許可済み     → フル機能（視線追跡）               │
│    └─ 拒否済み     → 固定視線モード（frame02）          │
└──────────────────────────────────────────────────────┘
```

権限状態を enum で表現：

```swift
// MARK: - GazePermissionStatus.swift

enum GazePermissionStatus {
    case notDetermined   // 未確認（初回起動時）
    case granted         // 許可済み → フル視線追跡
    case denied          // 拒否済み → 固定視線 frame02
}
```

---

### 11.2 視線モード定義

```swift
// MARK: - GazeMode.swift

/// 視線の動作モード
enum GazeMode: Equatable {
    /// AX API でターミナル座標を取得して4フレームに量子化する
    case tracking
    /// 固定フレームを使う（理由付き）
    case fixed(GazeFrame, reason: FixedGazeReason)
}

enum FixedGazeReason {
    case permissionDenied        // アクセシビリティ権限なし
    case terminalNotFound        // 対応ターミナル未検出
    case terminalInOtherSpace    // ターミナルが別 Space にある
    case terminalMinimized       // ターミナルが最小化されている
    case unsupportedTerminal     // 非対応ターミナル（AX属性が取得できない）
    case mascotStateOverride     // error/done など状態側から視線を固定
}

extension GazeMode {
    /// 視線が固定かどうか（フレーム番号が変化しないか）
    var isFixed: Bool {
        if case .fixed = self { return true }
        return false
    }
}
```

---

### 11.3 各シナリオの振る舞い仕様

| シナリオ | GazeMode | 表示フレーム | 備考 |
|---------|----------|------------|------|
| 権限許可 + ターミナル検出 | `.tracking` | frame02〜05（動的） | フル機能 |
| 権限許可 + ターミナル未検出 | `.fixed(.f01_center, .terminalNotFound)` | frame01 | ターミナル起動待ち |
| 権限許可 + 別 Space | `.fixed(.f01_center, .terminalInOtherSpace)` | frame01 | Space 戻り検知で自動回復 |
| 権限許可 + 最小化 | `.fixed(.f01_center, .terminalMinimized)` | frame01 | 最小化解除で自動回復 |
| 権限許可 + Warp（AX非対応） | `.fixed(.f02_rightDown, .unsupportedTerminal)` | frame02 | 将来対応を予告 |
| 権限拒否 | `.fixed(.f02_rightDown, .permissionDenied)` | frame02 | 右下固定でナチュラルに見える |
| error 状態 | `.fixed(.f01_center, .mascotStateOverride)` | frame07→10→11 | 状態優先 |
| sleeping 状態 | `.fixed(.f01_center, .mascotStateOverride)` | 目閉じ | 状態優先 |

---

### 11.4 GazeController 実装雛形

```swift
// MARK: - GazeController.swift

import AppKit
import ApplicationServices

final class GazeController {
    
    // MARK: - Types
    
    private let supportedBundles: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.desktop",       // Warp（AX属性確認後に追加）
        "org.wezfurlong.wezterm"
    ]
    
    // MARK: - State
    
    private(set) var mode: GazeMode = .fixed(.f02_rightDown, reason: .terminalNotFound)
    private(set) var permissionStatus: GazePermissionStatus = .notDetermined
    
    private var pollTimer: Timer?
    
    // MARK: - Public API
    
    func start() {
        checkPermission()
        startPolling()
    }
    
    func stop() {
        pollTimer?.invalidate()
    }
    
    // MARK: - Permission
    
    private func checkPermission() {
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt: false] as CFDictionary
        )
        permissionStatus = trusted ? .granted : .denied
        
        if permissionStatus == .denied {
            mode = .fixed(.f02_rightDown, reason: .permissionDenied)
        }
    }
    
    /// 初回起動時のみ呼び出す（権限ダイアログを出す）
    func requestPermissionIfNeeded(completion: @escaping (GazePermissionStatus) -> Void) {
        guard permissionStatus == .notDetermined else {
            completion(permissionStatus)
            return
        }
        
        // ダイアログを出す
        let _ = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt: true] as CFDictionary
        )
        
        // 1秒後に再チェック（ダイアログ応答を待つ簡易ポーリング）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.checkPermission()
            completion(self?.permissionStatus ?? .denied)
        }
    }
    
    // MARK: - Polling
    
    private func startPolling() {
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: 0.5,
            repeats: true
        ) { [weak self] _ in
            self?.updateGaze()
        }
    }
    
    private func updateGaze() {
        guard permissionStatus == .granted else { return }
        
        guard
            let terminalCenter = findFrontmostTerminalCenter(),
            let iconCenter = statusItemCenter()
        else {
            mode = .fixed(.f01_center, reason: .terminalNotFound)
            return
        }
        
        mode = .tracking
        // 視線方向を4択に量子化（GazeFrame への変換はこの関数内のみ）
        let frame = quantizeDirection(from: iconCenter, to: terminalCenter)
        gazeFrame = frame
    }
    
    // MARK: - AX API
    
    private func findFrontmostTerminalCenter() -> CGPoint? {
        let workspace = NSWorkspace.shared
        
        guard
            let frontApp = workspace.runningApplications.first(where: {
                $0.isActive && supportedBundles.contains($0.bundleIdentifier ?? "")
            })
        else { return nil }
        
        let pid = frontApp.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              let frontWindow = windows.first
        else { return nil }
        
        // 別 Space の場合は position が取得できない
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(frontWindow, kAXPositionAttribute as CFString, &posRef) == .success,
            AXUIElementCopyAttributeValue(frontWindow, kAXSizeAttribute as CFString, &sizeRef) == .success
        else {
            // 取得失敗 = 別SpaceまたはAX非対応
            self.mode = .fixed(.f01_center, reason: .terminalInOtherSpace)
            return nil
        }
        
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        
        return CGPoint(
            x: position.x + size.width / 2,
            y: position.y + size.height / 2
        )
    }
    
    private func statusItemCenter() -> CGPoint? {
        // NSStatusItem の座標は ClabotchApp から渡す（循環依存回避）
        return statusItemCenterProvider?()
    }
    
    // 外部から座標を注入（NSStatusItem の frame を提供する closure）
    var statusItemCenterProvider: (() -> CGPoint?)?
    
    // MARK: - Quantization
    
    private(set) var gazeFrame: GazeFrame = .f02_rightDown
    
    private func quantizeDirection(from origin: CGPoint, to target: CGPoint) -> GazeFrame {
        let dx = target.x - origin.x
        // macOS 座標系は Y が下向き正なので反転
        let dy = -(target.y - origin.y)
        
        // 4方向に量子化
        switch (dx >= 0, dy >= 0) {
        case (true,  false): return .f02_rightDown
        case (false, false): return .f03_leftDown
        case (false, true):  return .f04_leftUp
        case (true,  true):  return .f05_rightUp
        default:             return .f02_rightDown
        }
    }
}
```

---

### 11.5 オンボーディング UI 仕様（初回起動）

```
┌──────────────────────────────────────────────┐
│  🤖  Clabotch へようこそ                       │
│                                              │
│  Claude Code の作業をメニューバーで見守ります。   │
│                                              │
│  視線追跡機能を使うには                         │
│  アクセシビリティの許可が必要です。               │
│                                              │
│  ┌────────────────────────────────────────┐  │
│  │  「許可する」を押すとシステム設定が開きます │  │
│  └────────────────────────────────────────┘  │
│                                              │
│        [後で]            [許可する]            │
└──────────────────────────────────────────────┘
```

- 「許可する」→ `AXIsProcessTrustedWithOptions(prompt: true)` を呼び出す
- 「後で」→ 固定視線モードで起動 + メニューバー右クリックから「視線追跡を有効にする」で再表示
- **権限を拒否した場合でも機能の95%は動作する**ことを明示する

---

### 11.6 フォールバック優先順位まとめ

```
GazeController の優先順位（高 → 低）

1. mascotStateOverride（error/sleeping など状態側が視線を制御）
2. permissionDenied（権限なし → frame02 固定）
3. tracking（AX API でリアルタイム追跡）
4. terminalInOtherSpace / terminalMinimized → frame01 固定
5. terminalNotFound → frame01 固定
6. unsupportedTerminal → frame02 固定
```

---

## 12. MVP Definition

### 12.1 StateMachine 設計（MVP → 複数セッション拡張対応）

#### 状態の定義

```swift
// MARK: - MascotPhase.swift

/// マスコットの表示フェーズ
enum MascotPhase: Equatable {
    case idle
    case thinking                              // LLM応答待ち
    case working(toolName: String)             // ツール実行中
    case done(elapsedMs: Int)                  // 完了（アニメ後 idle に戻る）
    case error(toolName: String, message: String?)  // エラー（アニメ後 thinking に戻る）
    case sleeping                              // 長時間無操作（クライアント管理）
}

/// セッション単位の状態
struct SessionState: Equatable {
    let sessionID: String
    var phase: MascotPhase
    let startedAt: Date
    var lastEventAt: Date
}
```

#### MVP StateMachine（単一セッション）

```swift
// MARK: - StateMachine.swift

import Foundation

/// MVP: 単一セッション版 StateMachine
/// 将来の複数セッション対応は MultiSessionStateMachine で wrap する
final class StateMachine {
    
    // MARK: - State
    
    private(set) var session: SessionState?
    private(set) var displayPhase: MascotPhase = .idle
    
    private var sleepTimer: Timer?
    private let sleepThreshold: TimeInterval = 300  // 5分無操作でsleeping
    
    // MARK: - Callback
    
    /// 表示フェーズが変わったときに呼ばれる
    var onPhaseChanged: ((MascotPhase) -> Void)?
    
    // MARK: - Public API
    
    func handle(event: ClabotchEvent) {
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
                let nextPhase = MascotPhase.error(toolName: toolName, message: errorMessage)
                session?.phase = nextPhase
                transition(to: nextPhase)
                // エラーアニメ完了後 thinking に戻る（呼び出し側でコールバックを受けて遅延実行）
                scheduleAutoTransition(to: .thinking, after: 2.5)
            } else {
                session?.phase = .thinking
                transition(to: .thinking)
            }
            
        case .sessionDone(let sessionID, let elapsedMs):
            guard isActiveSession(sessionID) else { return }
            transition(to: .done(elapsedMs: elapsedMs))
            session = nil
            // 完了アニメ後 idle に戻る
            scheduleAutoTransition(to: .idle, after: 4.0)
            
        case .unknown:
            break
        }
    }
    
    // MARK: - Private
    
    private func isActiveSession(_ sessionID: String) -> Bool {
        session?.sessionID == sessionID
    }
    
    private func transition(to phase: MascotPhase) {
        guard displayPhase != phase else { return }
        displayPhase = phase
        DispatchQueue.main.async { [weak self] in
            self?.onPhaseChanged?(phase)
        }
    }
    
    private func scheduleAutoTransition(to phase: MascotPhase, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.transition(to: phase)
        }
    }
    
    private func resetSleepTimer() {
        sleepTimer?.invalidate()
        if displayPhase == .sleeping {
            transition(to: session != nil ? .thinking : .idle)
        }
        sleepTimer = Timer.scheduledTimer(withTimeInterval: sleepThreshold, repeats: false) { [weak self] _ in
            self?.transition(to: .sleeping)
        }
    }
}
```

#### 将来の複数セッション対応（v0.3 向け雛形）

```swift
// MARK: - MultiSessionStateMachine.swift（v0.3 スケルトン）

/// 複数セッション対応版（v0.3 で SingleSession を wrap する形で実装）
final class MultiSessionStateMachine {
    
    private var sessions: [String: SessionState] = [:]
    
    /// 表示優先度：error > working > thinking > done > idle > sleeping
    var displayPhase: MascotPhase {
        let phases = sessions.values.map(\.phase)
        return phases.highest ?? .idle
    }
    
    func handle(event: ClabotchEvent) {
        // 各 sessionID に対応する StateMachine を生成/管理
        // ここは v0.3 で実装
    }
}

extension Collection where Element == MascotPhase {
    var highest: MascotPhase? {
        self.min { a, b in a.displayPriority < b.displayPriority }
    }
}

extension MascotPhase {
    /// 数値が小さいほど優先表示される
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
```

---

### 12.2 フレーム仕様と状態表の整合修正

既存仕様書の「マスコット状態一覧」に不整合があった箇所を修正する。

#### 修正前（既存仕様書）

| 状態 | 視線 | 表情フレーム |
|------|------|------------|
| `idle` | frame02（右下） | 01 |
| `error` | center | 07→10→11シェイク |

#### 修正後

| 状態（MascotPhase） | 視線 | 表情フレーム | まばたき | 吹き出し例 |
|-------------------|------|------------|---------|-----------|
| `.idle` | `fixed(.f02_rightDown, .mascotStateOverride)` | frame02 | 通常 | — |
| `.thinking` | `tracking` or fallback | frame05（右上） | 通常 | 「考えてます...」 |
| `.working` | `tracking` or fallback | frame02〜05（動的） | 通常 | 「{toolName} を実行中...」 |
| `.done` | `fixed(.f02_rightDown, .mascotStateOverride)` | frame08→09→12→13→14 | 通常 | 「完了！（{elapsed}）」 |
| `.error` | `fixed(.f01_center, .mascotStateOverride)` | frame07→10→11→10→07 | 停止 | 「エラーが出ました…」 |
| `.sleeping` | `fixed(.f01_center, .mascotStateOverride)` | frame06（閉じ） | 停止 | — |

**修正のポイント：**

1. `idle` の視線は **frame02 固定**（`mascotStateOverride`）。`tracking` しない。
   - 理由：セッションがなければターミナルを探す必要がない。むしろ無駄な AX API 呼び出しを防ぐ。

2. `error` の視線は **frame01（中央）固定** に変更（既存仕様は `center` と曖昧だった）。
   - `GazeFrame.f01_center` として enum に明示的に定義する。

3. `thinking` は **tracking モード** で右上（frame05）に引っ張られやすいが、
   GazeController の計算結果が `f05` になるとは限らない。
   - 「LLM応答待ちは右上を向く傾向がある」はコメントとして記述するが、
     強制はしない（`mascotStateOverride` は使わない）。

---

### 12.3 MVP スコープ定義

#### MVP（PoC〜v0.2）に含めるもの

| 機能 | 詳細 |
|------|------|
| メニューバー常駐 | NSStatusItem、22×14px |
| フレーム描画 | frame01〜06（視線4種 + まばたき） |
| まばたき | BlinkController、2.8〜5.5秒ランダム |
| 視線追跡 | GazeController（AX API / fallback） |
| Hook受信 | Unix Socket（$TMPDIR使用） |
| 状態遷移 | StateMachine（idle/thinking/working/done/error） |
| 完了アニメ | frame08→09→12→13→14、ジャンプ、吹き出し |
| エラーアニメ | frame07→10→11シェイク |
| sleeping | 5分タイマー |

#### MVP に含めないもの（v0.3 以降）

| 機能 | 理由 |
|------|------|
| 複数セッション並列表示 | StateMachine 拡張が必要 |
| 作業時間の詳細統計 | UI設計を別途検討 |
| 設定画面 | v1.0 スコープ |
| LaunchAgent 自動起動 | v1.0 スコープ |
| Warp 完全対応 | AX属性確認後に追加 |
| Apple 公証 / DMG | v1.0 スコープ（**見積もり3〜4日追加**） |

---

### 12.4 改訂版ロードマップ

前回レビュー指摘の Notarization 未計上を修正。

| Phase | 期間（修正） | 内容 | リスク |
|-------|------------|------|--------|
| **PoC** | 1日 | メニューバー表示 + まばたき + Socket受信確認 | 低 |
| **v0.1** | 3日（+1） | 視線追跡 + Hook受信 + StateMachine結合 | **Warp AX互換性** |
| **v0.2** | 2日 | DONE/ERROR アニメ + ジャンプ + 吹き出し | 低 |
| **v0.3** | 3日（+1） | 複数セッション並列 + 作業時間表示 | StateMachineリファクタ |
| **v1.0** | 4〜5日（+2〜3） | 設定画面 + LaunchAgent + **Notarization + DMG** | Apple Developer証明書 |

**Notarization の工数注意点：**
- Apple Developer Program 登録（未登録なら別途 ¥13,800/年）
- `xcrun notarytool submit` → Apple サーバー処理（30分〜2時間）
- Stapling（`xcrun stapler staple`）
- Gatekeeper テスト（別端末で確認推奨）

---

### 12.5 即座に反映すべき修正チェックリスト

前回レビュー + 今回追加指摘の対応状況：

- [x] Unix Socket を `$TMPDIR` ベースに変更（§10.4）
- [x] Hook JSON を `printf` ベースに変更（§10.4）
- [x] `session_start` イベントを追加（§10.1 / §10.4）
- [x] `thinking` 状態の取得方法を定義（§10.1）
- [x] `error` 検知方法を定義（`is_error` フラグ、§10.2）
- [x] 状態とフレームの不整合を修正（§12.2）
- [x] GazeController fallback 仕様を定義（§11）
- [x] 初回権限オンボーディング UI を定義（§11.5）
- [x] StateMachine の将来拡張構造を定義（§12.1）
- [x] Notarization をロードマップに追加（§12.4）

---

*追記 — 2026-03-10*  
*Clabotch — MIT License*
