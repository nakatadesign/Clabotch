# Clabotch 設計仕様書 — v3追補（実装前ハードニング）

> `clabotch_design_doc_v2.md` にそのまま追記できる補足章。  
> 本章は **§10.1 / §10.4 / §11.1 / §11.4 / §12.1 / §12.3 の補強** を目的とする。  
> 既存記述と矛盾する場合は、本章の内容を優先する。

---

## 13. 実装前ハードニング

### 13.1 イベント観測の限界と MVP での扱い

Claude Code hooks だけでは、**ツール未使用セッションの開始時刻**と**純粋な thinking 開始時刻**は正確には観測できない。  
そのため、MVP では以下の現実的な制約を明示する。

| 項目 | MVP での扱い |
|------|--------------|
| `session_start` | **最初の `PreToolUse` 到達時に擬似生成するローカルイベント** |
| ツール未使用セッション | `Stop` のみ観測可能。完了アニメは出すが、経過時間は `0` 扱いまたは非表示 |
| `thinking` | hook 起点の**推定状態**として扱う。厳密な開始時刻保証はしない |
| 作業時間表示 | `elapsed_ms > 0` のときのみ吹き出しに表示する |

#### `session_done` の unknown session 取り扱い

`session_done` を受信した時点で対応する `SessionState` が存在しない場合でも、  
イベントは破棄せず **ephemeral completion** として表示する。

```swift
// unknown session の Stop も捨てない
case .sessionDone(_, let elapsedMs):
    transition(to: .done(elapsedMs: elapsedMs))
    session = nil
    scheduleAutoTransition(
        to: .idle,
        after: 4.0,
        expectedSessionID: nil
    )
```

#### 吹き出し文言ルール

- `elapsed_ms > 0`: `完了！(3分42秒)`
- `elapsed_ms == 0`: `完了！`

> これにより、ツール未使用セッションでも完了演出だけは失わない。

---

### 13.2 Hook 送信の堅牢化

v2 の `printf` 化だけでは JSON 文字列のエスケープは保証されない。  
`tool_name` や `error_message` に引用符・改行・バックスラッシュが含まれる可能性を考慮し、  
hook 側に最小限の JSON escape helper を置く。

また、UUID 生成のための `python3` 依存は削除し、macOS 標準の `uuidgen` を使う。

#### 共通 helper

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

#### `tool_start` 送信例

```bash
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TOOL_NAME_ESCAPED=$(json_escape "${TOOL_NAME:-unknown}")

printf '{"schema_version":"1","event":"tool_start","session_id":"%s","event_id":"%s","timestamp":"%s","tool_name":"%s"}\n' \
  "$SESSION_ID" "$(generate_uuid)" "$NOW" "$TOOL_NAME_ESCAPED" \
  | send_json
```

#### `tool_end` 送信例

```bash
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TOOL_NAME_ESCAPED=$(json_escape "${TOOL_NAME:-unknown}")

IS_ERROR="false"
ERROR_JSON="null"
if [[ "${EXIT_CODE:-0}" != "0" ]]; then
  IS_ERROR="true"
  ERROR_JSON='"tool failed"'
fi

printf '{"schema_version":"1","event":"tool_end","session_id":"%s","event_id":"%s","timestamp":"%s","tool_name":"%s","duration_ms":%s,"is_error":%s,"error_message":%s}\n' \
  "$SESSION_ID" "$(generate_uuid)" "$NOW" "$TOOL_NAME_ESCAPED" "${TOOL_DURATION_MS:-0}" "$IS_ERROR" "$ERROR_JSON" \
  | send_json
```

#### 補足

- `error_message` の詳細取得は MVP では未対応でよい
- 送信は常に **best-effort**
- malformed JSON は `EventParser` 側で黙って破棄する

---

### 13.3 Accessibility 権限状態の修正

v2 の `checkPermission()` は、初回未確認状態を即 `denied` に潰してしまう。  
これではオンボーディング経由の permission prompt が出せない。

そのため、権限状態は **OS の現在状態** と **アプリが一度でもリクエストしたか** を分離して管理する。

```swift
// MARK: - PermissionState.swift

enum GazePermissionStatus {
    case notDetermined
    case granted
    case denied
}

private enum PermissionKeys {
    static let didRequestAccessibility = "didRequestAccessibility"
}
```

#### 判定ルール

```swift
private func checkPermission() {
    let trusted = AXIsProcessTrusted()
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

    guard permissionStatus == .notDetermined else {
        completion(permissionStatus)
        return
    }

    UserDefaults.standard.set(true, forKey: PermissionKeys.didRequestAccessibility)
    let _ = AXIsProcessTrustedWithOptions(
        [kAXTrustedCheckOptionPrompt: true] as CFDictionary
    )

    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
        self?.checkPermission()
        completion(self?.permissionStatus ?? .denied)
    }
}
```

#### 運用ルール

- `start()` では prompt を出さない
- 初回オンボーディングの `[許可する]` 操作でのみ prompt を出す
- `notDetermined` の間は `.fixed(.f02_rightDown, .permissionDenied)` ではなく、`temporaryFixed` 扱いで自然に表示する

---

### 13.4 Gaze fallback の分類見直し

v2 の実装雛形では、AX 取得失敗を `terminalInOtherSpace` に寄せすぎている。  
また Warp は「確認後に追加」と書きつつ `supportedBundles` に入っているため、仕様とコードが衝突している。

#### 修正ルール

1. MVP の `supportedBundles` は以下に限定する

```swift
private let supportedBundles: Set<String> = [
    "com.apple.Terminal",
    "com.googlecode.iterm2",
    "org.wezfurlong.wezterm"
]

private let tentativeBundles: Set<String> = [
    "dev.warp.desktop"
]
```

2. frontmost app の分類を先に行う

```swift
private func classifyFrontmostTerminal() -> FixedGazeReason? {
    let workspace = NSWorkspace.shared

    guard let frontApp = workspace.frontmostApplication else {
        return .terminalNotFound
    }

    let bundleID = frontApp.bundleIdentifier ?? ""

    if tentativeBundles.contains(bundleID) {
        return .unsupportedTerminal
    }

    guard supportedBundles.contains(bundleID) else {
        return .terminalNotFound
    }

    return nil
}
```

3. window 取得後の失敗理由を分ける

| 状況 | Reason |
|------|--------|
| frontmost が非対応端末 | `.unsupportedTerminal` |
| frontmost が端末ではない | `.terminalNotFound` |
| window が 0 件 | `.terminalMinimized` |
| window はあるが `position/size` 取得不可 | `.terminalInOtherSpace` |

> Warp を正式対応にするのは、AX 属性ダンプ確認後に `tentativeBundles` から `supportedBundles` へ移すタイミングとする。

---

### 13.5 StateMachine のレース対策

遅延遷移は、新しい外部イベントを受けた時点で必ず無効化する。  
`done` / `error` アニメの終了待ち中に次セッションが始まるケースを考慮し、  
**pending transition の cancel** と **epoch guard** を導入する。

```swift
final class StateMachine {

    private(set) var session: SessionState?
    private(set) var displayPhase: MascotPhase = .idle

    private var sleepTimer: Timer?
    private var pendingTransition: DispatchWorkItem?
    private var transitionEpoch: UInt = 0

    var onPhaseChanged: ((MascotPhase) -> Void)?

    func handle(event: ClabotchEvent) {
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
                let nextPhase = MascotPhase.error(toolName: toolName, message: errorMessage)
                session?.phase = nextPhase
                transition(to: nextPhase)
                scheduleAutoTransition(
                    to: .thinking,
                    after: 2.5,
                    expectedSessionID: sessionID
                )
            } else {
                session?.phase = .thinking
                transition(to: .thinking)
            }

        case .sessionDone(let sessionID, let elapsedMs):
            if isActiveSession(sessionID) {
                session = nil
            }
            transition(to: .done(elapsedMs: elapsedMs))
            scheduleAutoTransition(
                to: .idle,
                after: 4.0,
                expectedSessionID: nil
            )

        case .unknown:
            break
        }
    }

    private func scheduleAutoTransition(
        to phase: MascotPhase,
        after delay: TimeInterval,
        expectedSessionID: String?
    ) {
        let scheduledEpoch = transitionEpoch
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.transitionEpoch == scheduledEpoch else { return }
            guard expectedSessionID == nil || self.session?.sessionID == expectedSessionID else { return }
            self.transition(to: phase)
        }
        pendingTransition = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
```

#### sleeping の発火条件

`sleeping` は **セッション非存在時のみ** 有効にする。  
active session 中は `thinking` が長くても sleep に入らない。

```swift
private func resetSleepTimer() {
    sleepTimer?.invalidate()

    if displayPhase == .sleeping {
        transition(to: session != nil ? .thinking : .idle)
    }

    guard session == nil else { return }

    sleepTimer = Timer.scheduledTimer(withTimeInterval: sleepThreshold, repeats: false) { [weak self] _ in
        guard self?.session == nil else { return }
        self?.transition(to: .sleeping)
    }
}
```

---

### 13.6 MVP の明文化

MVP の定義に、観測限界と暫定仕様を明示する。

#### MVP に含める前提

- ツール使用セッションを主対象とする
- `thinking` は hook 由来の推定状態であり、厳密な実測ではない
- 完了時刻は `Stop` hook で確定する
- `session_done` 単独受信時も完了アニメは出す

#### MVP の既知制約

- ツール未使用セッションの経過時間は正確に測れない
- Warp は正式対応前は `.unsupportedTerminal` で固定視線に落とす
- `error_message` 詳細は v1.0 以降で改善余地あり

---

### 13.7 実装順の修正提案

実装順は以下に調整する。

1. Hook 実機検証
   `SESSION_ID` / `TOOL_NAME` / `EXIT_CODE` / `TOOL_DURATION_MS` の存在確認
2. HookServer + EventParser
   malformed JSON の黙殺、unknown event の記録
3. Single-session StateMachine
   cancel 可能な delayed transition を含む
4. GazeController
   Terminal / iTerm2 / WezTerm まで先行対応
5. Warp AX 調査
   属性ダンプ後に対応可否を判断

> 先に hook 実測を済ませることで、机上の schema 修正を減らせる。

---

*追補案 — 2026-03-10*  
*Clabotch — v3 hardening patch*
