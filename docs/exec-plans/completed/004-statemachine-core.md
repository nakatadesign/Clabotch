# 実装計画 004: StateMachine コア

## 概要

設計書 v11 §6（マスコット状態一覧）、§10.1（状態とイベントの対応表）、§12.2（StateMachine v8 最終版）に基づき、ClabotchEvent を受けて MascotPhase を遷移させる StateMachine コアを実装する。

StateMachine は main thread 専用の pure に近いコンポーネントであり、描画層（GazeController / BlinkController / BubbleWindow / ClabotchEyeView）や AX tracking との結合は本計画のスコープ外とする。

## 正典参照

- 設計書: `docs/design/current/clabotch_design_doc_v11.md`
- §6: マスコット状態一覧（L143-166）
- §10.1: 設計方針・状態とイベントの対応表（L265-274）
- §12.2: StateMachine v8 最終版（L929-1162）
- §13.5: StateMachine レース対策（L1254-1259）
- §14.2: single-session 防御線（L1394-1407）

## 正典からの逸脱（実装完了時に patch 文書に記録）

| # | 内容 | v11 正典 | 本計画 | 理由 |
|---|------|---------|--------|------|
| 1 | sleepThreshold パラメータ化 | `private let sleepThreshold = 300`（固定値） | `init(sleepThreshold:)` でデフォルト 300 付き外部注入 | テスタビリティ（5分待たずに sleep 遷移を検証可能にする） |
| 2 | auto-transition delay パラメータ化 | `2.5`（error→thinking）/ `4.0`（done→idle）固定値 | `init(errorAutoTransitionDelay:doneAutoTransitionDelay:)` でデフォルト付き | テスタビリティ（遅延秒数をテストで短縮可能にする） |
| 3 | Date 注入 | `Date()` 直接使用 | `now: @escaping () -> Date` クロージャ注入 | テスタビリティ（時刻を固定した deterministic テスト） |
| 4 | cancelSleepTimer sleeping 復帰ロジック削除 | `if displayPhase == .sleeping { transition(to: session != nil ? .thinking : .idle) }` | 削除（handle Step 3 で代替） | `handle(event:)` の Step 2 で `cancelSleepTimer()` → Step 3 で `transition(to: .thinking)` 等が呼ばれるため冗長。コード簡素化。 |
| 5 | onPhaseChanged / onEphemeralDone 同期呼び出し | `DispatchQueue.main.async { self?.onPhaseChanged?(phase) }` および `DispatchQueue.main.async { self?.onEphemeralDone?(elapsedMs) }` | 同期呼び出し `onPhaseChanged?(phase)` / `onEphemeralDone?(elapsedMs)` | `handle(event:)` / `handleForeign` 自体が main thread 上で実行されるため async 不要。同期にすることで epoch チェックとコールバック間のギャップを排除し、テストの deterministic 性を向上。 |

## 前提条件

- [x] 計画 003 完了（EventParser + EventDeduplicator + HookServer 結線、Codex A）
- [x] 全 80 テスト合格（79 passed, 1 skipped）

## スコープ

**含む:**
- `MascotPhase` enum（6 phase）
- `SessionState` struct
- `StateMachine` class（main thread only）
  - single-session ownership guard（`isOwned` / `isActiveSession`）
  - foreign event 処理（`handleForeign`）
  - phase 遷移（`transition(to:)`）
  - `transitionEpoch` / `pendingTransition` による delayed transition のレース対策
  - `sleepTimer`（session == nil && displayPhase == .idle の時のみ始動）
  - `onPhaseChanged` コールバック
  - `onEphemeralDone` コールバック（foreign session_done、ms > 0 のみ）
  - `start()` メソッド（初期フェーズ同期 + sleep タイマー始動）
- AppDelegate → StateMachine 結線（HookServer.onEvent → StateMachine.handle）
- 全テスト

**含まない:**
- GazeController / BlinkController / BubbleWindow / ClabotchEyeView
- AX / terminal tracking
- Stop hook error 対応

---

## Step 1: MascotPhase + SessionState 型定義

### 成果物

`src/Clabotch/MascotPhase.swift`

### 仕様

```swift
import Foundation

/// マスコットの表示状態。StateMachine の出力。
enum MascotPhase: Equatable {
    case idle
    case thinking
    case working(toolName: String)
    case done(elapsedMs: Int)
    case error(toolName: String, message: String?)
    case sleeping
}

/// アクティブセッションの状態。StateMachine 内部で保持。
struct SessionState: Equatable {
    let sessionID: String
    var phase: MascotPhase
    let startedAt: Date
    var lastEventAt: Date
}
```

### 設計根拠

- v11 §12.2 L929-943 の定義をそのまま採用
- `MascotPhase` は Equatable 自動合成（全 associated value が Equatable）
- `SessionState` は内部状態であり、テスト検証用に `Equatable` を付与

---

## Step 2: StateMachine 実装

### 成果物

`src/Clabotch/StateMachine.swift`

### 2a. プロパティとイニシャライザ

```swift
import Foundation
import os.log

final class StateMachine {
    // --- 公開状態 ---
    private(set) var session: SessionState?
    private(set) var displayPhase: MascotPhase = .idle

    // --- コールバック ---
    var onPhaseChanged: ((MascotPhase) -> Void)?
    var onEphemeralDone: ((Int) -> Void)?

    // --- レース対策 ---
    private var transitionEpoch: UInt = 0
    private var pendingTransition: DispatchWorkItem?

    // --- Sleep タイマー ---
    private var sleepTimer: Timer?
    private let sleepThreshold: TimeInterval

    // --- Auto-transition delay ---
    private let errorAutoTransitionDelay: TimeInterval
    private let doneAutoTransitionDelay: TimeInterval

    // --- DI seams ---
    private let now: () -> Date

    init(
        sleepThreshold: TimeInterval = 300,
        errorAutoTransitionDelay: TimeInterval = 2.5,
        doneAutoTransitionDelay: TimeInterval = 4.0,
        now: @escaping () -> Date = { Date() }
    ) {
        self.sleepThreshold = sleepThreshold
        self.errorAutoTransitionDelay = errorAutoTransitionDelay
        self.doneAutoTransitionDelay = doneAutoTransitionDelay
        self.now = now
    }
}
```

### 2b. start() メソッド

```swift
func start() {
    dispatchPrecondition(condition: .onQueue(.main))
    onPhaseChanged?(displayPhase)
    startSleepTimerIfNeeded()
}
```

### 2c. handle(event:) メソッド — Ownership-First Guard

```swift
func handle(event: ClabotchEvent) {
    dispatchPrecondition(condition: .onQueue(.main))

    // Step 1: Ownership 判定（副作用ゼロ）
    guard isOwned(event) else {
        handleForeign(event)
        return
    }

    // Step 2: 副作用適用（owned 確定後のみ）
    transitionEpoch &+= 1
    pendingTransition?.cancel()
    pendingTransition = nil
    cancelSleepTimer()

    // Step 3: 状態遷移
    let currentDate = now()
    switch event {
    case .sessionStart(let sessionID):
        session = SessionState(
            sessionID: sessionID,
            phase: .thinking,
            startedAt: currentDate,
            lastEventAt: currentDate
        )
        transition(to: .thinking)

    case .toolStart(_, let toolName):
        session?.lastEventAt = currentDate
        session?.phase = .working(toolName: toolName)
        transition(to: .working(toolName: toolName))

    case .toolEnd(let sessionID, let toolName, _, let isError, let errorMessage):
        session?.lastEventAt = currentDate
        if isError {
            let p = MascotPhase.error(toolName: toolName, message: errorMessage)
            session?.phase = p
            transition(to: p)
            scheduleAutoTransition(to: .thinking, after: errorAutoTransitionDelay,
                                   expectedSessionID: sessionID)
        } else {
            session?.phase = .thinking
            transition(to: .thinking)
        }

    case .sessionDone(_, let elapsedMs):
        session = nil
        transition(to: .done(elapsedMs: elapsedMs))
        scheduleAutoTransition(to: .idle, after: doneAutoTransitionDelay,
                               expectedSessionID: nil)

    case .unknown:
        break // isOwned で false を返すため到達しないが念のため
    }
}
```

### 2d. isOwned / isActiveSession

```swift
private func isOwned(_ event: ClabotchEvent) -> Bool {
    switch event {
    case .sessionStart:
        return session == nil
    case .toolStart(let id, _),
         .toolEnd(let id, _, _, _, _),
         .sessionDone(let id, _):
        return isActiveSession(id)
    case .unknown:
        return false
    }
}

private func isActiveSession(_ id: String) -> Bool {
    session?.sessionID == id
}
```

### 2e. handleForeign

```swift
private func handleForeign(_ event: ClabotchEvent) {
    switch event {
    case .sessionDone(_, let elapsedMs):
        guard elapsedMs > 0 else { return }  // ms == 0 は silent drop
        onEphemeralDone?(elapsedMs)
    case .sessionStart(let id):
        if session?.sessionID == id {
            os_log(.debug, "重複 session_start（no-op）: %{public}@", id)
        } else {
            os_log(.debug, "foreign session_start 無視: %{public}@", id)
        }
    case .toolStart(let id, _):
        os_log(.debug, "foreign tool_start 無視: %{public}@", id)
    case .toolEnd(let id, _, _, _, _):
        os_log(.debug, "foreign tool_end 無視: %{public}@", id)
    case .unknown:
        break
    }
}
```

### 2f. transition(to:)

```swift
private func transition(to phase: MascotPhase) {
    guard displayPhase != phase else { return }
    displayPhase = phase

    if case .idle = phase {
        startSleepTimerIfNeeded()
    }

    onPhaseChanged?(phase)
}
```

**設計根拠:**
- v11 §12.2 L1105-1109 では `DispatchQueue.main.async` で onPhaseChanged を呼んでいるが、handle(event:) 自体が main thread 上で実行されるため、同期呼び出しで十分。非同期にすると epoch チェックとコールバックの間にギャップが生まれるリスクがある。テスト時の deterministic 性も向上する。
- この差異は逸脱テーブル #5 に記録済み。

### 2g. scheduleAutoTransition

```swift
private func scheduleAutoTransition(
    to phase: MascotPhase,
    after delay: TimeInterval,
    expectedSessionID: String?
) {
    let epoch = transitionEpoch
    let work = DispatchWorkItem { [weak self] in
        guard let self else { return }
        guard self.transitionEpoch == epoch else { return }
        guard expectedSessionID == nil
           || self.session?.sessionID == expectedSessionID
        else { return }
        self.transition(to: phase)
    }
    pendingTransition = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
}
```

### 2h. Sleep タイマー

```swift
private func startSleepTimerIfNeeded() {
    guard session == nil else { return }
    guard case .idle = displayPhase else { return }
    sleepTimer?.invalidate()
    sleepTimer = Timer.scheduledTimer(
        withTimeInterval: sleepThreshold, repeats: false
    ) { [weak self] _ in
        guard let self else { return }
        guard self.session == nil else { return }
        self.transition(to: .sleeping)
    }
}

private func cancelSleepTimer() {
    sleepTimer?.invalidate()
    sleepTimer = nil
}
```

**注意:** v11 L1133-1139 の `cancelSleepTimer` は sleeping 中に owned event が来た場合の復帰処理を含むが、本実装では `handle(event:)` の Step 3 で適切な phase に遷移するため、cancelSleepTimer 自体で復帰する必要はない。Step 2 で `cancelSleepTimer()` → Step 3 で `transition(to: .thinking)` 等が呼ばれるため、sleeping → thinking の遷移は自然に発生する。この差異は逸脱テーブル #4 に記録済み。

---

## Step 3: AppDelegate 結線

### 変更対象

`src/Clabotch/AppDelegate.swift`

### 変更内容

```swift
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var hookServer: HookServer?
    private let deduplicator = EventDeduplicator()
    private let stateMachine = StateMachine()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // メニューバーに「C」を表示
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "C"

        // メニュー構築
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit Clabotch", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem?.menu = menu

        // StateMachine コールバック設定
        stateMachine.onPhaseChanged = { phase in
            os_log(.info, "フェーズ変更: %{public}@", String(describing: phase))
        }
        stateMachine.onEphemeralDone = { elapsedMs in
            os_log(.info, "ephemeral done: %d ms", elapsedMs)
        }

        // HookServer 初期化・起動
        let tmpDir = NSTemporaryDirectory().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let socketDir = "/" + tmpDir + "/clabotch"

        hookServer = HookServer(
            socketDir: socketDir,
            deduplicator: deduplicator,
            onEvent: { [weak self] envelope in
                self?.stateMachine.handle(event: envelope.event)
            },
            onListenerFailure: { error in
                os_log(.fault, "HookServer listener が停止: %{public}@", String(describing: error))
            }
        )

        do {
            try hookServer?.start()
            os_log(.info, "HookServer started")
            stateMachine.start()
        } catch let error as HookServerError where error == .alreadyRunning {
            os_log(.error, "既に別インスタンスが起動中")
            NSApplication.shared.terminate(nil)
        } catch {
            os_log(.error, "HookServer failed to start: %{public}@", error.localizedDescription)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hookServer?.terminateSync()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
```

---

## Step 4: テスト

### 成果物

`src/ClabotchTests/StateMachineTests.swift`

### テスト分類

#### 4a. Ownership Guard テスト（6 件）

| # | テスト名 | 検証内容 |
|---|---------|---------|
| 1 | `testSessionStartAcceptedWhenNoSession` | session == nil で session_start → thinking に遷移 |
| 2 | `testDuplicateSessionStartIsNoOp` | active session 中に同一 ID の session_start → phase 変化なし |
| 3 | `testForeignSessionStartIgnored` | active session 中に別 ID の session_start → phase 変化なし |
| 4 | `testForeignToolStartIgnored` | active session 中に別 session_id の tool_start → phase 変化なし |
| 5 | `testForeignToolEndIgnored` | active session 中に別 session_id の tool_end → phase 変化なし |
| 6 | `testForeignSessionDoneIgnored` | active session 中に別 session_id の session_done(ms==0) → phase 変化なし、ephemeral なし |

#### 4b. Phase 遷移テスト（8 件）

| # | テスト名 | 検証内容 |
|---|---------|---------|
| 7 | `testSessionStartSetsThinking` | session_start → displayPhase == .thinking、session != nil |
| 8 | `testToolStartSetsWorking` | thinking → tool_start → displayPhase == .working(toolName) |
| 9 | `testToolEndSuccessSetsThinking` | working → tool_end(isError:false) → displayPhase == .thinking |
| 10 | `testToolEndErrorSetsError` | working → tool_end(isError:true) → displayPhase == .error(toolName, message) |
| 11 | `testSessionDoneSetsDone` | thinking → session_done → displayPhase == .done(elapsedMs)、session == nil |
| 12 | `testErrorAutoTransitionToThinking` | error → 2.5秒後 → thinking に自動遷移 |
| 13 | `testDoneAutoTransitionToIdle` | done → 4秒後 → idle に自動遷移 |
| 14 | `testUnknownEventIsNoOp` | unknown イベント → phase 変化なし |

#### 4c. Delayed Transition レース対策テスト（4 件）

| # | テスト名 | 検証内容 |
|---|---------|---------|
| 15 | `testNewEventCancelsPendingTransition` | error 中に新しい tool_start → 2.5秒後の auto-transition 発火しない |
| 16 | `testEpochInvalidatesStaleTransition` | done 中に新しい session_start → 4秒後の auto-transition 発火しない |
| 17 | `testSessionDoneCancelsPendingErrorTransition` | error → session_done → error の auto-transition 発火しない、done の auto-transition のみ発火 |
| 18 | `testPendingTransitionSessionIDMismatch` | error auto-transition の expectedSessionID が session 変更で不一致 → no-op |

#### 4d. Sleeping テスト（4 件）

| # | テスト名 | 検証内容 |
|---|---------|---------|
| 19 | `testSleepingFiresAfterThreshold` | idle + session==nil → sleepThreshold 後 → sleeping |
| 20 | `testSleepingNotFiresWithActiveSession` | idle + session!=nil → sleepThreshold 後 → sleeping にならない |
| 21 | `testSleepingCancelledBySessionStart` | sleeping 中に session_start → thinking（sleeping 解除） |
| 22 | `testSleepTimerRestartsOnReturnToIdle` | done → idle auto-transition → sleep タイマー再始動 |

#### 4e. Ephemeral 通知テスト（3 件）

| # | テスト名 | 検証内容 |
|---|---------|---------|
| 23 | `testForeignSessionDoneEphemeral` | foreign session_done(ms > 0) → onEphemeralDone コールバック |
| 24 | `testForeignSessionDoneZeroMsSilentDrop` | foreign session_done(ms == 0) → onEphemeralDone 呼ばれない |
| 25 | `testActiveSessionDoneNoEphemeral` | active session_done → onEphemeralDone 呼ばれない（normal done 遷移） |

#### 4f. onPhaseChanged コールバックテスト（2 件）

| # | テスト名 | 検証内容 |
|---|---------|---------|
| 26 | `testOnPhaseChangedCalledOnTransition` | 遷移時に onPhaseChanged が正しい phase で呼ばれる |
| 27 | `testOnPhaseChangedNotCalledForSamePhase` | 同一 phase への遷移 → onPhaseChanged 呼ばれない |

### テスト合計

- StateMachineTests: 27 件
- 既存テスト: 80 件（79 passed, 1 skipped）
- **目標合計: 107 件（106 passed, 1 skipped）**

### テスト設計方針

1. **Timer を使わない deterministic テスト**: auto-transition テスト（#12, #13, #15-18, #22）は `DispatchQueue.main.asyncAfter` ベースの遅延を `XCTestExpectation` + short delay で検証する。init の delay パラメータを 0.1 秒等に短縮して高速化。

2. **Sleeping テストの Timer 制御**: sleepThreshold を 0.2 秒に短縮し、Timer.scheduledTimer の実行を `RunLoop.main.run(until:)` で回して検証。

3. **main thread 保証**: 全テストを `@MainActor` で実行し、`dispatchPrecondition` が通ることを保証。

4. **副作用の検証**: `onPhaseChanged` と `onEphemeralDone` のクロージャでコールバック回数・引数を記録。

---

## Step 5: xcodegen + ビルド + テスト実行

```bash
cd src && xcodegen generate && xcodebuild test -project Clabotch.xcodeproj -scheme Clabotch -destination 'platform=macOS'
```

目標: 107 テスト全通過（106 passed, 1 skipped）

---

## Step 6: Codex 実装レビュー

レビュー観点:
- v11 §12.2 との整合性
- single-session ownership guard の正確性
- transitionEpoch / pendingTransition のレース対策
- sleeping 条件の正確性
- テストカバレッジ

---

## 既存テスト分類（80 件）

| テストクラス | 件数 | 変更 |
|-------------|------|------|
| EventParserTests | 18 | なし |
| EventDeduplicatorTests | 7 | なし |
| HookServerUnitTests | 20 | なし |
| HookServerIntegrationTests | 21 | なし |
| HookServerAppDelegateTests | 3 | なし |
| LineBufferedEventDecoderTests | 11 | なし |
| **合計** | **80** | |

---

## 完了基準

- [ ] MascotPhase / SessionState 型定義
- [ ] StateMachine 実装（全メソッド）
- [ ] AppDelegate 結線
- [ ] StateMachineTests 27 件作成
- [ ] 全 107 テスト合格
- [ ] Codex 実装レビュー A 取得
