# Clabotch 設計仕様書 — v8パッチ（Gaze override責務 / 初回idle sleep / 文言整合）

> `clabotch_design_doc_v7.md` への差分パッチ。  
> 本章は **§11.5 / §11.6 / §12.2 / §14.3** の補強を目的とする。  
> v7 と矛盾する場合は本章を優先する。

---

## 修正一覧

| # | 優先度 | 対象 | v7 の残課題 | v8 の修正 |
|---|--------|------|-------------|-----------|
| 1 | P1 | §11.5 / §11.6 | `mascotStateOverride` が仕様上は最優先だが、`GazeController.update()` が常時 `mode/gazeFrame` を上書きしてしまう | `GazeController` に state override API を追加し、override 有効中は tracking 更新を停止する |
| 2 | P2 | §12.2 | sleeping タイマーが「完了後 idle」では再始動するが、アプリ初回 idle では起動しない | `start()` を追加し、初期 idle でも `startSleepTimerIfNeeded()` を呼ぶ |
| 3 | P3 | §14.3 | 「active session と同一 ID のイベントは受理する」が `session_start` 冪等化ルールとズレる | `session_start` を別扱いにして表現を修正する |

---

## 15. v8 修正詳細

### 15.1 `mascotStateOverride` の責務を `GazeController` に閉じる

#### 問題

v7 では仕様表で次を主張している。

- `idle` → `fixed(.f02, .mascotStateOverride)`
- `error` → `fixed(.f01, .mascotStateOverride)`
- `sleeping` → `fixed(.f01, .mascotStateOverride)`
- 優先順位 1 位は `mascotStateOverride`

しかし実装雛形の `GazeController.update()` は 0.5 秒ごとに必ず  
`permissionStatus` / `frontmostTerminal` / `quantize(...)` を評価して  
`mode` と `gazeFrame` を更新してしまう。  
このままだと override は別レイヤーの「口約束」になり、責務が曖昧。

#### v8 の設計方針

`GazeController` 自体に **state override API** を持たせる。  
override が有効な間は `update()` は早期 return し、tracking/fallback 計算を停止する。

#### 追加 API

```swift
enum GazeOverride {
    case none
    case fixed(frame: GazeFrame, reason: FixedGazeReason)
}
```

```swift
final class GazeController {

    private(set) var mode: GazeMode = .fixed(.f02_rightDown, reason: .terminalNotFound)
    private(set) var gazeFrame: GazeFrame = .f02_rightDown

    // v8: 状態機械からの override
    private var override: GazeOverride = .none

    func setOverride(_ override: GazeOverride) {
        self.override = override

        switch override {
        case .none:
            break
        case .fixed(let frame, let reason):
            mode = .fixed(frame, reason: reason)
            gazeFrame = frame
        }
    }

    private func update() {
        // v8: mascotStateOverride が最優先
        if case .fixed(let frame, let reason) = override {
            mode = .fixed(frame, reason: reason)
            gazeFrame = frame
            return
        }

        checkPermission()

        guard permissionStatus == .granted else {
            let reason: FixedGazeReason =
                (permissionStatus == .notDetermined) ? .permissionNotDetermined : .permissionDenied
            mode = .fixed(.f02_rightDown, reason: reason)
            gazeFrame = .f02_rightDown
            return
        }

        if let reason = classifyFrontmostTerminal() {
            let frame: GazeFrame = (reason == .unsupportedTerminal) ? .f02_rightDown : .f01_center
            mode = .fixed(frame, reason: reason)
            gazeFrame = frame
            return
        }

        guard
            let frontApp = NSWorkspace.shared.frontmostApplication,
            let origin = statusItemCenterProvider?()
        else { return }

        let (center, failReason) = findTerminalCenter(pid: frontApp.processIdentifier)
        if let reason = failReason {
            mode = .fixed(.f01_center, reason: reason)
            gazeFrame = .f01_center
            return
        }

        if let target = center {
            mode = .tracking
            gazeFrame = quantize(from: origin, to: target)
        }
    }
}
```

#### StateMachine からの適用規約

| `MascotPhase` | `GazeController.setOverride(...)` |
|---------------|-----------------------------------|
| `.idle` | `.fixed(frame: .f02_rightDown, reason: .mascotStateOverride)` |
| `.thinking` | `.none` |
| `.working` | `.none` |
| `.done` | `.fixed(frame: .f02_rightDown, reason: .mascotStateOverride)` |
| `.error` | `.fixed(frame: .f01_center, reason: .mascotStateOverride)` |
| `.sleeping` | `.fixed(frame: .f01_center, reason: .mascotStateOverride)` |

#### 実装上のルール

- `onPhaseChanged` を受ける Coordinator / AppDelegate が `GazeController.setOverride(...)` を呼ぶ
- `GazeController` は phase を知らない
- `StateMachine` は gaze の内部実装を知らない

> これで `mascotStateOverride` が「仕様だけ最優先」ではなく、実装責務として閉じる。

---

### 15.2 初回 idle でも sleeping タイマーを起動する

#### 問題

v7 の `startSleepTimer()` は `transition(.idle)` 内でしか呼ばれない。  
そのため、アプリ起動直後にイベントが一度も来ない場合、  
初期 `displayPhase = .idle` のまま sleep タイマーが始まらない。

#### v8 の設計方針

`StateMachine` に明示的な `start()` API を追加し、  
初期 idle 表示に入った時点で `startSleepTimerIfNeeded()` を呼ぶ。

#### 修正後の API

```swift
final class StateMachine {

    private(set) var session: SessionState?
    private(set) var displayPhase: MascotPhase = .idle

    func start() {
        guard session == nil else { return }
        startSleepTimerIfNeeded()
    }

    private func transition(to phase: MascotPhase) {
        guard displayPhase != phase else { return }
        displayPhase = phase

        if case .idle = phase {
            startSleepTimerIfNeeded()
        }

        DispatchQueue.main.async { [weak self] in
            self?.onPhaseChanged?(phase)
        }
    }

    private func startSleepTimerIfNeeded() {
        guard session == nil else { return }
        guard displayPhase == .idle else { return }

        sleepTimer?.invalidate()
        sleepTimer = Timer.scheduledTimer(
            withTimeInterval: sleepThreshold,
            repeats: false
        ) { [weak self] _ in
            guard self?.session == nil else { return }
            self?.transition(to: .sleeping)
        }
    }
}
```

#### 起動順

`applicationDidFinishLaunching` で次の順に呼ぶ。

1. `stateMachine.start()`
2. `gazeController.startPolling()`
3. 必要ならオンボーディング表示

#### 効果

- 初回起動後、何もイベントが来なくても 5 分後に `.sleeping` へ遷移する
- `done -> idle` 復帰後も同じ `startSleepTimerIfNeeded()` を再利用できる

---

### 15.3 §14.3 の single-session 表現を修正する

#### v7 の問題

`§14.3` の表は次のようになっていた。

- `active session と同一 ID のイベント | 受理する`

しかし v7 の `isOwned(.sessionStart)` は **`session == nil` のみ true** であり、  
同一 `session_id` の重複 `session_start` は no-op である。  
つまり `session_start` だけは「同一 ID でも受理する」に当てはまらない。

#### 修正後の表現

| 状況 | 挙動 |
|------|------|
| `session == nil` で `session_start` | 受理して active session にする |
| active session 中の重複 `session_start`（同一 ID） | **no-op（debug log のみ）** |
| active session と同一 ID の `tool_start` / `tool_end` / `session_done` | 受理する |
| active session と異なる `session_start` / `tool_*` | 無視（debug log のみ） |
| active session と異なる `session_done(ms > 0)` | `onEphemeralDone` のみ（2秒吹き出し） |
| active session と異なる `session_done(ms == 0)` | **silent drop** |

#### 追記文

> `session_start` はセッション生成イベントであり、  
> 冪等性を優先して **同一 `session_id` の再送でも no-op** とする。  
> 一方で `tool_*` と `session_done` は active session の継続イベントとして扱う。

---

## v8 適用後の読み替え

| 章 | v8 での読み替え |
|----|-----------------|
| §11.5 / §11.6 | `mascotStateOverride` は `GazeController.setOverride()` で実装責務として担保する |
| §12.2 | `StateMachine.start()` を初回起動時に呼び、初期 idle でも sleep タイマーを始動する |
| §14.3 | `session_start` は同一 ID 再送でも no-op、他イベントと分けて解釈する |

---

## 実装可否の判断

この v8 を反映すれば、v7 時点で残っていた設計上の曖昧さはほぼ消える。  
以降は設計レビューより実装と PoC 検証を優先してよい。

---

*v8 patch — 2026-03-10*  
*Clabotch — MIT License*
