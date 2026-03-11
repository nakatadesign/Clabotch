# 実装計画 007: CoordinatorBinder 抽出 + 下流連携テスト

## 概要

AppDelegate の Coordinator 結線ロジック（`onPhaseChanged` / `onEphemeralDone` callback 設定）を **`CoordinatorBinder`** クラスに抽出し、テスト環境で **結線ロジック自体** を直接検証する。

計画 002〜006 で実装済みの StateMachine → GazeController / BlinkController / ClabotchEyeView / BubbleWindow の下流連携が正しく機能していることを、CoordinatorBinder を通した統合テストで検証する。

**テスト範囲**: CoordinatorBinder.bind() が設定する callback 経由の下流連携全体。テストは CoordinatorBinder.bind() の **結線ロジック**（callback 設定・変換ロジック）を自動テストでカバーする。**ただし AppDelegate が CoordinatorBinder を正しく生成・保持し bind() を呼ぶことの検証は手動確認に依存する**（残留リスク §リスク参照）。AppDelegate 側の残コードは binder 生成 + bind() 呼び出しの数行のみであり、目視で検証可能な範囲に限定される。

**テスト対象外**: HookServer → StateMachine の結線は計画 003 の統合テスト（testValidNDJSONProducesEvent 等）で検証済みのため、本計画のスコープ外とする。

## 正典参照

- 設計書: `docs/design/current/clabotch_design_doc_v11.md`
- §6: マスコット状態一覧（L149-156）— phase ごとの視線・まばたき・表情・吹き出し期待値
- §6: 吹き出し文言規約（L158-165）— active done(ms>0/ms==0), foreign done(ms>0), foreign done(ms==0)=silent drop
- §10.3: 受信パイプライン — イベント→状態遷移→UI 更新の流れ
- §11.5: Coordinator 責務 — AppDelegate が担う結線の仕様
- §12.2: StateMachine — error auto-transition は **thinking** へ（v8最終版、L1036）; done auto-transition は **idle** へ（L1044-1045、4秒後）
- design patch: `docs/design/patches/patch_004_sync_onPhaseChanged.md` — onPhaseChanged の同期呼び出し

## 正典からの逸脱

| # | 内容 | v11 正典 | 本計画 | 理由 |
|---|------|---------|--------|------|
| 1 | BubbleWindow の統合テストで show() を呼ばない | §5: 吹き出し 3 秒表示 | headless 環境で NSWindow 生成が Signal 11 クラッシュするため、BubbleSpy（BubblePresenting 準拠の test double）で show/dismiss の呼び出しを検証する。実 NSWindow の表示は手動確認 | xcodebuild test が headless 実行のため |
| 2 | AppDelegate から結線ロジックを CoordinatorBinder に抽出 | §11.5: AppDelegate が Coordinator | AppDelegate は NSStatusItem / NSApplication に依存し直接テスト不可。結線ロジック（callback 設定 + 変換メソッド）を CoordinatorBinder クラスに抽出し、AppDelegate は CoordinatorBinder を生成して bind() を呼ぶだけとする。テストは CoordinatorBinder.bind() を直接実行し結線ロジックを検証する。**ただし AppDelegate 側に残る (1) binder 生成・保持・bind() 呼び出し、(2) gazeController.statusItemCenterProvider の設定（NSStatusItem 座標取得、視線追跡の必須結線）は自動テストのスコープ外**（残留リスク参照）。目視レビューで十分カバー可能な範囲に限定 | テスト可能性の確保。AppDelegate のコード行数変化は最小限（callback 代入を bind() 呼び出しに置換） |
| 3 | HookServer → StateMachine の結線は対象外 | §10.3: 受信パイプライン全体 | 本計画は StateMachine 以降の fan-out に集中する。HookServer → StateMachine は計画 003 の統合テスト（testValidNDJSONProducesEvent 等）で検証済み | スコープ限定 |
| 4 | onPhaseChanged の同期呼び出し | §12.2 疑似コード L1111: `DispatchQueue.main.async { self?.onPhaseChanged?(phase) }` | 実装（`StateMachine.swift` L168）では `onPhaseChanged?(phase)` を同期呼び出し。design patch `patch_004_sync_onPhaseChanged.md` で文書化済み。テストは **async-tolerant パターン**を使用し、将来の dispatch 戦略変更にも耐える設計とする | main thread 専用制約により main.async は不要な遅延。patch_004 で承認済み |
| 5 | onEphemeralDone の同期呼び出し（既存実装差分） | §12.2 疑似コード L1077-1078: `DispatchQueue.main.async { self?.onEphemeralDone?(elapsedMs) }` | 実装（`StateMachine.swift` L142）では `onEphemeralDone?(elapsedMs)` を同期呼び出し。**patch_004 は onPhaseChanged のみを対象としており、onEphemeralDone の同期化は未承認の既存実装差分**。本計画はこの既存実装を変更せず、テストは async-tolerant パターンで将来の dispatch 変更にも耐える設計とする。onEphemeralDone 用の companion patch は本計画のスコープ外とし、必要に応じて別途作成する | 既存実装の動作を前提としたテスト。patch 化は別途判断 |

## 前提条件

- [x] 計画 002〜006 完了（全コンポーネント実装済み、Codex A）
- [x] 全 170 テスト合格（169 passed, 1 skipped）
- [x] AppDelegate.swift に全結線が実装済み
- [x] design patch_004 作成済み

## スコープ

**含む:**
- BubblePresenting プロトコル: BubbleWindow の show/dismiss インターフェース抽象化
- CoordinatorBinder: AppDelegate から抽出した結線ロジック（実プロダクションコード）
- BubbleSpy: BubblePresenting 準拠の test double
- AppDelegate リファクタリング: callback 直接代入 → CoordinatorBinder.bind() 呼び出しに変更
- 統合テスト: CoordinatorBinder.bind() 経由の下流連携検証（21 テスト）
- static 変換メソッドの CoordinatorBinder 移設
- phase 遷移 → 下流コンポーネント状態の整合性検証
- auto-transition 検証: error → thinking（0.3秒 DI）、done → idle（0.3秒 DI）
- ephemeral done: foreign session_done(ms>0) と silent drop(ms==0)
- 起動順保証テスト（stateMachine.start() → gazeController.startPolling()）

**含まない:**
- HookServer → StateMachine の結線テスト（計画 003 でカバー済み）
- BubbleWindow DI 拡張（テスト seam 改善はバックログ）
- canvas 中央配置 / frame 09-14 アニメーション / Warp 対応 / AX 権限 UI / Stop hook error

## ファイル構成

### 新規ファイル

| ファイル | 役割 |
|----------|------|
| `src/Clabotch/BubblePresenting.swift` | 吹き出し表示プロトコル（BubbleWindow と BubbleSpy が準拠） |
| `src/Clabotch/CoordinatorBinder.swift` | AppDelegate から抽出した結線ロジック（実プロダクションコード） |
| `src/ClabotchTests/BubbleSpy.swift` | BubblePresenting 準拠の test double |
| `src/ClabotchTests/CoordinatorIntegrationTests.swift` | 統合テスト本体（21 テスト） |
| `docs/design/patches/patch_004_sync_onPhaseChanged.md` | onPhaseChanged 同期呼び出しの design patch（作成済み） |

### 変更ファイル

| ファイル | 変更内容 |
|----------|---------:|
| `src/Clabotch/AppDelegate.swift` | callback 直接代入 → CoordinatorBinder 生成 + bind() 呼び出しに変更。static 変換メソッドを CoordinatorBinder に移設 |
| `src/Clabotch/BubbleWindow.swift` | BubblePresenting 準拠宣言を追加 |
| `src/ClabotchTests/AppDelegateCoordinatorTests.swift` | static メソッド参照を `AppDelegate.` → `CoordinatorBinder.` に変更 |

## 詳細設計

### Step 1: BubblePresenting プロトコル

BubbleWindow と BubbleSpy が共通で準拠する吹き出し表示プロトコル。

```swift
/// 吹き出し表示のプロトコル。
/// BubbleWindow（プロダクション）と BubbleSpy（テスト）が準拠する。
protocol BubblePresenting: AnyObject {
    func show(text: String, anchor: CGPoint, duration: TimeInterval)
    func dismiss()
}

extension BubblePresenting {
    /// デフォルト duration 3.0 秒
    func show(text: String, anchor: CGPoint) {
        show(text: text, anchor: anchor, duration: 3.0)
    }
}
```

BubbleWindow に `extension BubbleWindow: BubblePresenting {}` を追加（既存の show/dismiss シグネチャがそのまま準拠する）。

### Step 2: CoordinatorBinder

AppDelegate の `onPhaseChanged` / `onEphemeralDone` callback 設定ロジック、static 変換メソッド、および関連する os_log 出力を移設した実プロダクションコード。

```swift
import Foundation
import os.log

/// StateMachine → 下流コンポーネントの結線を担当する Coordinator。
/// AppDelegate から抽出し、自動テストで結線パスを直接検証可能にする。
final class CoordinatorBinder {
    let stateMachine: StateMachine
    let gazeController: GazeController
    let blinkController: BlinkController
    weak var eyeView: ClabotchEyeView?
    let activeBubble: BubblePresenting
    let ephemeralBubble: BubblePresenting
    var anchorProvider: () -> CGPoint?

    init(
        stateMachine: StateMachine,
        gazeController: GazeController,
        blinkController: BlinkController,
        eyeView: ClabotchEyeView?,
        activeBubble: BubblePresenting,
        ephemeralBubble: BubblePresenting,
        anchorProvider: @escaping () -> CGPoint?
    ) {
        self.stateMachine = stateMachine
        self.gazeController = gazeController
        self.blinkController = blinkController
        self.eyeView = eyeView
        self.activeBubble = activeBubble
        self.ephemeralBubble = ephemeralBubble
        self.anchorProvider = anchorProvider
    }

    /// StateMachine の callback を設定する。AppDelegate.applicationDidFinishLaunching から呼ばれる。
    func bind() {
        // GazeController → ClabotchEyeView
        gazeController.onGazeFrameChanged = { [weak self] frame in
            self?.eyeView?.setGazeFrame(frame)
        }

        // BlinkController → ClabotchEyeView
        blinkController.onBlink = { [weak self] in
            self?.eyeView?.triggerBlink()
        }

        // StateMachine → Coordinator fan-out
        stateMachine.onPhaseChanged = { [weak self] phase in
            guard let self else { return }
            os_log(.info, "フェーズ変更: %{public}@", String(describing: phase))

            let override = Self.gazeOverride(for: phase)
            self.gazeController.setOverride(override)

            let blinkEnabled = Self.isBlinkEnabled(for: phase)
            self.blinkController.setBlinking(enabled: blinkEnabled)

            self.eyeView?.setPhaseAppearance(phase: phase)

            if let text = Self.bubbleText(for: phase) {
                if let anchor = self.anchorProvider() {
                    self.activeBubble.show(text: text, anchor: anchor)
                }
            } else {
                self.activeBubble.dismiss()
            }
        }

        stateMachine.onEphemeralDone = { [weak self] elapsedMs in
            guard let self else { return }
            let text = Self.formatElapsedTime(elapsedMs)
            let display = "別セッション完了 (\(text))"
            if let anchor = self.anchorProvider() {
                self.ephemeralBubble.show(text: display, anchor: anchor, duration: 2.0)
            }
        }
    }

    // MARK: - Phase → Override 変換（v11 §11.5 対応表準拠）

    static func gazeOverride(for phase: MascotPhase) -> GazeOverride {
        switch phase {
        case .idle:     return .fixed(frame: .f02_rightDown, reason: .mascotStateOverride)
        case .thinking: return .none
        case .working:  return .none
        case .done:     return .fixed(frame: .f02_rightDown, reason: .mascotStateOverride)
        case .error:    return .fixed(frame: .f01_center, reason: .mascotStateOverride)
        case .sleeping: return .fixed(frame: .f01_center, reason: .mascotStateOverride)
        }
    }

    // MARK: - Phase → Blink 変換（v11 §6 準拠）

    static func isBlinkEnabled(for phase: MascotPhase) -> Bool {
        switch phase {
        case .idle, .thinking, .working, .done: return true
        case .error, .sleeping:                 return false
        }
    }

    // MARK: - Phase → 吹き出し文言（v11 §6 準拠）

    static func bubbleText(for phase: MascotPhase) -> String? {
        switch phase {
        case .thinking:
            return "考えてます..."
        case .working(let toolName):
            return "\(toolName) 実行中..."
        case .done(let elapsedMs):
            if elapsedMs > 0 {
                return "完了！(\(formatElapsedTime(elapsedMs)))"
            } else {
                return "完了！"
            }
        case .error:
            return "エラーが出ました…"
        case .idle, .sleeping:
            return nil
        }
    }

    // MARK: - ヘルパー

    static func formatElapsedTime(_ ms: Int) -> String {
        let totalSeconds = ms / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes > 0 {
            return "\(minutes)分\(seconds)秒"
        } else {
            return "\(seconds)秒"
        }
    }
}
```

### Step 3: AppDelegate リファクタリング

AppDelegate から結線ロジックと static 変換メソッドを除去し、CoordinatorBinder に委譲する。

変更前（L56-88, L130-184）: `onPhaseChanged` / `onEphemeralDone` callback の直接代入、static 変換メソッド 4 つ
変更後: `CoordinatorBinder` を生成して `bind()` を呼び出し

```swift
// AppDelegate 変更後の applicationDidFinishLaunching 抜粋
private var binder: CoordinatorBinder?

// ... statusItem / eyeView / menu 設定は変更なし ...

// GazeController のステータスアイテム中心座標プロバイダ
gazeController.statusItemCenterProvider = { [weak self] in
    // ... 既存コードそのまま ...
}

// Coordinator 結線（CoordinatorBinder に委譲）
binder = CoordinatorBinder(
    stateMachine: stateMachine,
    gazeController: gazeController,
    blinkController: blinkController,
    eyeView: eyeView,
    activeBubble: bubbleWindow,
    ephemeralBubble: ephemeralBubbleWindow,
    anchorProvider: { [weak self] in self?.statusItemAnchor() }
)
binder?.bind()

// HookServer 初期化・起動 ... 変更なし ...
// stateMachine.start() → gazeController.startPolling() の順は変更なし
```

既存の AppDelegateCoordinatorTests.swift は `AppDelegate.gazeOverride(for:)` → `CoordinatorBinder.gazeOverride(for:)` 等に参照先を変更する。

### Step 4: BubbleSpy

BubblePresenting に準拠する test double。NSWindow を生成せず、呼び出しを記録する。

```swift
import XCTest
@testable import Clabotch

/// BubblePresenting 準拠の test double。
/// headless テスト環境で NSWindow 生成を回避し、show/dismiss の呼び出しを記録する。
final class BubbleSpy: BubblePresenting {
    struct ShowCall {
        let text: String
        let anchor: CGPoint
        let duration: TimeInterval
    }

    private(set) var showCalls: [ShowCall] = []
    private(set) var explicitDismissCount: Int = 0
    private(set) var isShowing: Bool = false
    private(set) var lastText: String?

    func show(text: String, anchor: CGPoint, duration: TimeInterval = 3.0) {
        dispatchPrecondition(condition: .onQueue(.main))
        // 実物 BubbleWindow 準拠: show() のたびに先に dismiss() する
        if isShowing {
            dismiss()
        }
        isShowing = true
        lastText = text
        showCalls.append(ShowCall(text: text, anchor: anchor, duration: duration))
    }

    func dismiss() {
        dispatchPrecondition(condition: .onQueue(.main))
        explicitDismissCount += 1
        isShowing = false
    }

    func reset() {
        showCalls = []
        explicitDismissCount = 0
        isShowing = false
        lastText = nil
    }
}
```

**BubbleSpy と BubbleWindow の振る舞い一致**: BubbleSpy は BubblePresenting プロトコルに準拠し、BubbleWindow と同一インターフェースで動作する。show() 内の `if isShowing { dismiss() }` は BubbleWindow.show() L23 の `dismiss()` と同等。プロトコル準拠により、シグネチャの不一致はコンパイル時に検出される。

### Step 5: CoordinatorIntegrationTests

#### メインスレッド実行モデル

StateMachine / GazeController / BlinkController / ClabotchEyeView は全て main thread 専用（dispatchPrecondition 検証済み）。テストクラスに `@MainActor` を付与し、刺激投入・待機・検証を全て main run loop 上で統一する。

#### setUp — CoordinatorBinder による実コード結線

```swift
@MainActor
final class CoordinatorIntegrationTests: XCTestCase {
    var stateMachine: StateMachine!
    var gazeController: GazeController!
    var blinkController: BlinkController!
    var eyeView: ClabotchEyeView!
    var activeBubbleSpy: BubbleSpy!
    var ephemeralBubbleSpy: BubbleSpy!
    var binder: CoordinatorBinder!
    var mockAX: MockAXProvider!
    var mockWorkspace: MockWorkspaceProvider!

    override func setUp() {
        super.setUp()

        // DI パラメータ（テスト高速化）
        stateMachine = StateMachine(
            sleepThreshold: 0.5,
            errorAutoTransitionDelay: 0.3,
            doneAutoTransitionDelay: 0.3
        )
        mockAX = MockAXProvider()
        mockWorkspace = MockWorkspaceProvider()
        gazeController = GazeController(
            axProvider: mockAX,
            workspaceProvider: mockWorkspace,
            pollInterval: 0.1
        )
        blinkController = BlinkController(
            intervalRange: 0.1...0.2,
            randomSource: { 0.0 }
        )
        eyeView = ClabotchEyeView(frame: NSRect(x: 0, y: 0, width: 22, height: 14))

        activeBubbleSpy = BubbleSpy()
        ephemeralBubbleSpy = BubbleSpy()

        // GazeController のステータスアイテム中心座標プロバイダ（テスト用固定値）
        gazeController.statusItemCenterProvider = { CGPoint(x: 500, y: 300) }

        // CoordinatorBinder — 実プロダクションコードの bind() を呼ぶ
        binder = CoordinatorBinder(
            stateMachine: stateMachine,
            gazeController: gazeController,
            blinkController: blinkController,
            eyeView: eyeView,
            activeBubble: activeBubbleSpy,
            ephemeralBubble: ephemeralBubbleSpy,
            anchorProvider: { CGPoint(x: 100, y: 100) }
        )
        binder.bind()

        // UserDefaults 初期化（GazeController permission 判定の依存を防止）
        UserDefaults.standard.removeObject(forKey: "didRequestAccessibility")

        // 起動順は AppDelegate と同じ
        stateMachine.start()
        gazeController.startPolling()
    }

    override func tearDown() {
        // AppDelegate.applicationWillTerminate と同等のクリーンアップ
        activeBubbleSpy.dismiss()
        ephemeralBubbleSpy.dismiss()
        blinkController.setBlinking(enabled: false)
        gazeController.stopPolling()
        UserDefaults.standard.removeObject(forKey: "didRequestAccessibility")
        super.tearDown()
    }
}
```

**テストが検証するもの**: CoordinatorBinder.bind() で設定される callback は **実プロダクションコードそのもの** である。テスト harness が callback ロジックを複製するのではなく、CoordinatorBinder.bind() を直接呼び出すため、結線ロジックの正当性を自動テストで検証できる。**ただし AppDelegate が CoordinatorBinder を正しく生成・保持し bind() を呼ぶことは自動テスト外であり、目視レビューに依存する**（残留リスク参照）。

### Async-tolerant テストパターン

テストは将来の dispatch 戦略変更（sync → async）にも耐える **async-tolerant パターン**を採用する。

**直接 handle(event:) の検証**: `stateMachine.displayPhase` の変化を KVO-like にポーリングするか、下流コンポーネントの **observable state**（`eyeView.faceColor`, `blinkController.isBlinking`, `activeBubbleSpy.lastText` 等）で待機する。bind() が設定した callback を**差し替えない**ことで、production wiring を壊さず検証できる。

```swift
// パターン例: phase 変化後の下流検証（observable state で待機）
stateMachine.handle(event: .sessionStart(sessionID: "s1"))
// 現実装は同期（patch_004）のため即座に下流更新が完了するが、
// 将来 async に変わっても耐えるよう expectation で待機
let exp = expectation(description: "bubble shows thinking text")
// ポーリングで observable state を検証
Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
    if self.activeBubbleSpy.lastText == "考えてます..." {
        timer.invalidate()
        exp.fulfill()
    }
}
waitForExpectations(timeout: 2.0)
// 下流状態を検証
XCTAssertEqual(blinkController.isBlinking, true)
```

**重要: bind() が設定した callback を差し替えない**。E1/F1 を含む全テストケースで、`onGazeFrameChanged` / `onBlink` / `onPhaseChanged` / `onEphemeralDone` を上書きしない。代わりに下流の **observable state**（`eyeView.gazeFrame`, `eyeView.isBlinkClosed`, `activeBubbleSpy.lastText`, `ephemeralBubbleSpy.showCalls` 等）の変化をポーリングまたは短い sleep 後に検証する。これにより production wiring パスが完全に保持される。

**auto-transition の検証**: DI パラメータで delay を 0.3 秒に短縮。下流の observable state（`stateMachine.displayPhase`, `eyeView` の状態フラグ等）をポーリングで待機。timeout 2.0 秒で十分なマージン確保。

**否定テスト**: `XCTestExpectation(isInverted: true)` を使用。指定時間内に fulfill **されない**ことを検証する。否定テストでのみ、下流の observable state 変化をトリガーに fulfill する一時的なポーリングを使用する。

| ケース | 待機方法 | timeout |
|--------|---------|---------|
| handle(event:) → phase 変更 | observable state ポーリング（activeBubbleSpy.lastText / eyeView 状態） | 2.0s |
| error → thinking auto-transition | observable state ポーリング（stateMachine.displayPhase == .thinking） | 2.0s |
| done → idle auto-transition | observable state ポーリング（stateMachine.displayPhase == .idle） | 2.0s |
| idle → sleeping timer | observable state ポーリング（stateMachine.displayPhase == .sleeping） | 2.0s |
| onEphemeralDone | observable state ポーリング（ephemeralBubbleSpy.showCalls.count 変化） | 2.0s |
| GazeController polling → EyeView gazeFrame | observable state ポーリング（eyeView.gazeFrame 変化） | 2.0s |
| BlinkController → EyeView blink | observable state ポーリング（eyeView.isBlinkClosed == true） | 2.0s |
| blink 未発火（F2） | XCTestExpectation(isInverted: true) + ポーリング（eyeView.isBlinkClosed 変化で fulfill） | 0.5s |
| ephemeral silent drop（D3） | XCTestExpectation(isInverted: true) + ポーリング（ephemeralBubbleSpy.showCalls.count 変化で fulfill） | 0.5s |
| foreign no-op（H2-H4） | XCTestExpectation(isInverted: true) | 0.5s |

### テストケース一覧

#### A. Full Session Flow（6 テスト）

| # | テスト名 | 検証内容 |
|---|---------|---------|
| A1 | `testSessionStartSetsThinkingPhase` | sessionStart → thinking。BlinkController isBlinking=true、EyeView faceColor=Palette.faceNormal・showErrorX=false・showSurprise=false、activeBubbleSpy lastText="考えてます..."。GazeController の override は .none に設定されるが、mode/gazeFrame への反映は次回 poll 依存のため本テストでは検証しない（E1 で poll 後の observable behavior を検証） |
| A2 | `testToolStartSetsWorkingPhase` | thinking 中に toolStart → working。activeBubbleSpy lastText に toolName を含む。GazeController override は .none のまま |
| A3 | `testToolEndSuccessReturnsToThinking` | working 中に toolEnd(isError:false) → thinking。activeBubbleSpy lastText="考えてます..."（v11 §6 L152: tool_end成功後 → thinking） |
| A4 | `testSessionDoneWithElapsedTime` | sessionDone(elapsedMs: 222000) → done。GazeController mode=.fixed(.f02_rightDown, reason: .mascotStateOverride)、EyeView showSurprise=true、activeBubbleSpy lastText="完了！(3分42秒)" |
| A5 | `testSessionDoneZeroMsShowsCompletionOnly` | sessionDone(elapsedMs: 0) → done。activeBubbleSpy lastText="完了！"（v11 §6 L163） |
| A6 | `testDoneAutoTransitionToIdle` | done 後に doneAutoTransitionDelay（0.3秒）経過 → idle。EyeView showSurprise=false、activeBubbleSpy dismiss 呼び出し（bubbleText(.idle)==nil → dismiss）。XCTestExpectation で .idle 到達を待機 |

#### B. Error Flow（2 テスト）

| # | テスト名 | 検証内容 |
|---|---------|---------|
| B1 | `testToolEndWithErrorSetsErrorPhase` | toolEnd(isError:true) → error。GazeController mode=.fixed(.f01_center, reason: .mascotStateOverride)、BlinkController isBlinking=false、EyeView showErrorX=true、activeBubbleSpy lastText="エラーが出ました…" |
| B2 | `testErrorAutoTransitionToThinking` | error 後に errorAutoTransitionDelay（0.3秒）経過 → **thinking** 復帰（v11 §12.2 L1036）。EyeView showErrorX=false、faceColor=Palette.faceNormal、activeBubbleSpy lastText="考えてます..."。XCTestExpectation で .thinking 到達を待機 |

#### C. Sleeping Flow（2 テスト）

| # | テスト名 | 検証内容 |
|---|---------|---------|
| C1 | `testSleepingPhaseAfterThreshold` | idle で sleepThreshold（0.5秒）経過 → sleeping。GazeController mode=.fixed(.f01_center, reason: .mascotStateOverride)（v11 §6 L156）、BlinkController isBlinking=false、EyeView isBlinkClosed=true・faceColor=Palette.faceSleep、activeBubbleSpy lastText==nil（吹き出しなし）。XCTestExpectation で .sleeping 到達を待機 |
| C2 | `testSleepingCancelledBySessionStart` | sleeping 中に sessionStart → thinking。EyeView isBlinkClosed=false（setPhaseAppearance で .thinking の外見に更新） |

#### D. Ephemeral Done（3 テスト）

| # | テスト名 | 検証内容 |
|---|---------|---------|
| D1 | `testEphemeralDoneShowsOnSeparateBubble` | foreign sessionDone(elapsedMs: 72000) → ephemeralBubbleSpy に show 呼び出し（text="別セッション完了 (1分12秒)"、duration=2.0）。activeBubbleSpy の showCalls.count は変化なし。XCTestExpectation で ephemeralBubbleSpy.show を待機 |
| D2 | `testEphemeralDoneWithActivePhase` | working 中に foreign sessionDone → activeBubbleSpy の lastText は working 文言のまま変化なし |
| D3 | `testForeignDoneZeroMsSilentDrop` | foreign sessionDone(elapsedMs: 0) → XCTestExpectation(isInverted: true) で ephemeralBubbleSpy.show が**呼ばれない**ことを検証（v11 §6 L165: silent drop）。timeout: 0.5秒 |

#### E. GazeController → EyeView（2 テスト）

| # | テスト名 | 検証内容 |
|---|---------|---------|
| E1 | `testGazeTrackingPropagatesFrameToEyeView` | thinking phase（override=none）→ インスタンス変数 `mockAX.isTrusted=true`, `mockWorkspace.bundleIdentifier="com.apple.Terminal"`, `mockWorkspace.pid=12345`, `mockAX.terminalCenter=CGPoint(x:100,y:500)` を setUp 後に書き換え → polling で gazeFrame 再計算 → **eyeView.gazeFrame** の変化をポーリングで待機（bind() が設定した onGazeFrameChanged callback を差し替えない。production wiring パスが eyeView まで貫通していることを end-to-end で検証） |
| E2 | `testGazeOverrideFixedSetsFrameImmediately` | setOverride(.fixed(f01, .mascotStateOverride)) → 即座に gazeFrame=.f01_center → EyeView.gazeFrame=.f01_center |

#### F. BlinkController → EyeView（2 テスト）

| # | テスト名 | 検証内容 |
|---|---------|---------|
| F1 | `testBlinkCallbackTriggersEyeViewBlink` | BlinkController が onBlink 発火 → **eyeView.isBlinkClosed==true** をポーリングで待機（bind() が設定した onBlink callback を差し替えない。production wiring パスが eyeView まで貫通していることを end-to-end で検証） |
| F2 | `testBlinkDisabledStopsCallback` | error phase → BlinkController.isBlinking=false。XCTestExpectation(isInverted: true) で **eyeView.isBlinkClosed** が true に**ならない**ことを検証。timeout: 0.5秒（複数 interval 相当） |

#### G. 起動順保証（1 テスト）

| # | テスト名 | 検証内容 |
|---|---------|---------|
| G1 | `testStartupOrderSetsOverrideBeforePolling` | stateMachine.start() 呼び出し後、gazeController.startPolling() 呼び出し前に、gazeController.mode == .fixed(.f02_rightDown, reason: **.mascotStateOverride**) であることを検証。GazeController の初期 mode は .fixed(.f02_rightDown, reason: **.terminalNotFound**) なので、reason の違いで setOverride() が start() 経由で呼ばれたことを証明できる。このテストのみ setUp の起動順を使わず、個別に start() / startPolling() を呼び分ける |

#### H. テスト独立性・Cleanup・No-op 検証（3 テスト）

| # | テスト名 | 検証内容 |
|---|---------|---------|
| H1 | `testCleanupStopsAllTimers` | **前提**: まず thinking phase に遷移させる（override=none にするため）。mockAX.isTrusted=true, mockWorkspace.bundleIdentifier="com.apple.Terminal", mockWorkspace.pid=12345, mockAX.terminalCenter=CGPoint(x:100,y:500) を設定し、polling で gazeFrame が変化することを確認。**検証**: tearDown 相当の cleanup（stopPolling + setBlinking(false) + dismiss×2）を実行後、mockAX.terminalCenter を別の座標に変更し、0.3 秒待機しても eyeView.gazeFrame が変化しないことを XCTestExpectation(isInverted: true) で確認（pollTimer が停止した証拠）。blinkController.isBlinking==false も検証。**注意**: idle phase では override が有効で update() が打ち切られるため、thinking phase（override=none）での検証が必須 |
| H2 | `testForeignSessionStartNoFanOut` | **前提**: まず sessionStart("s1") で active session を確立（thinking phase）。その後、activeBubbleSpy.showCalls.count を記録。**検証**: 別 sessionID の sessionStart("s-foreign") を送信 → StateMachine は active session が存在するため foreign 扱いで drop。activeBubbleSpy.showCalls.count が変化しないことを XCTestExpectation(isInverted: true) で確認。timeout: 0.5秒。**注意**: active session がないと sessionStart は owned 扱いで thinking に遷移してしまう |
| H3 | `testDuplicateSessionStartNoFanOut` | 同一 sessionID で sessionStart を 2 回送信 → 2 回目は StateMachine が drop。activeBubbleSpy showCalls.count が 1 のまま。XCTestExpectation(isInverted: true) で追加 fan-out **されない**ことを検証。timeout: 0.5秒 |

**合計: 21 テスト**

### 自動テスト vs 手動確認の切り分け

| 項目 | 自動テスト | 手動確認 | 理由 |
|------|-----------|---------|------|
| CoordinatorBinder.bind() 結線ロジック | ✅ 実プロダクションコード実行 | — | テストが CoordinatorBinder.bind() を直接呼ぶ |
| StateMachine → phase 遷移 | ✅ XCTestExpectation | — | async-tolerant パターン |
| auto-transition（error→thinking, done→idle） | ✅ XCTestExpectation | — | DI で delay 短縮 + expectation |
| phase → GazeController mode/gazeFrame | ✅ | — | mode / gazeFrame が private(set) で読み取り可能 |
| phase → BlinkController isBlinking | ✅ | — | isBlinking が private(set) で読み取り可能 |
| phase → EyeView 状態フラグ | ✅ | — | private(set) で読み取り可能 |
| phase → BubblePresenting show/dismiss | ✅ BubbleSpy | — | プロトコル準拠で型安全 |
| ephemeral vs active bubble 分離 | ✅ BubbleSpy×2 | — | 2 インスタンスの独立性を検証 |
| ephemeral silent drop (ms==0) | ✅ isInverted expectation | — | 否定テスト |
| foreign / duplicate no-op | ✅ isInverted expectation | — | 否定テスト |
| GazeController → EyeView.gazeFrame | ✅ | — | MockAXProvider + polling |
| BlinkController → EyeView.triggerBlink | ✅ | — | onBlink → isBlinkClosed 連鎖 |
| BlinkController 停止（否定テスト） | ✅ isInverted expectation | — | 複数 interval 相当待機 |
| 起動順保証 | ✅ mode.reason 差分 | — | .terminalNotFound → .mascotStateOverride |
| cleanup（timer 停止） | ✅ | — | isBlinking / stopPolling / dismiss |
| AppDelegate → CoordinatorBinder 生成・保持・bind() 呼び出し | — | ✅ | AppDelegate は binder 生成 + bind() の数行。NSStatusItem 依存で headless テスト不可。目視レビュー + 将来の GUI smoke test で補完 |
| 実際の BubbleWindow 表示 | — | ✅ | headless で NSWindow 生成不可 |
| 実際の EyeView 画面描画 | — | ✅ | Core Graphics 描画結果の目視確認 |
| メニューバーアイコンのクリック | — | ✅ | NSStatusItem の操作は GUI 環境のみ |

### テスト数

| 区分 | テスト数 |
|------|---------|
| 既存テスト | 170（169 passed, 1 skipped） |
| 新規統合テスト | 21 |
| **合計目標** | **191**（190 passed, 1 skipped） |

## 実装手順

1. `docs/design/patches/patch_004_sync_onPhaseChanged.md` を作成（済み）
2. `src/Clabotch/BubblePresenting.swift` を作成
3. `src/Clabotch/BubbleWindow.swift` に BubblePresenting 準拠宣言を追加
4. `src/Clabotch/CoordinatorBinder.swift` を作成（AppDelegate から結線ロジック + static メソッドを移設）
5. `src/Clabotch/AppDelegate.swift` をリファクタリング（CoordinatorBinder 生成 + bind() 呼び出し）
6. `src/ClabotchTests/AppDelegateCoordinatorTests.swift` の static メソッド参照を更新
7. `src/ClabotchTests/BubbleSpy.swift` を作成
8. `src/ClabotchTests/CoordinatorIntegrationTests.swift` を作成（@MainActor + setUp で CoordinatorBinder.bind() + 起動順再現、テストケース 21 件）
9. xcodegen generate + xcodebuild test で全テスト通過を確認
10. 計画書を completed に移動

## リスク

| リスク | 対策 |
|--------|------|
| AppDelegate リファクタリングで既存動作が壊れる | CoordinatorBinder は AppDelegate の結線コードを**そのまま移設**する（os_log 含む）。static メソッドのロジック変更はゼロ。既存テスト（170 件）の再実行で回帰を検出 |
| **AppDelegate 側の残コード（binder 生成 + bind() + statusItemCenterProvider 設定）が自動検証されない** | AppDelegate は NSStatusItem / NSApplication に依存するため headless テストでインスタンス化できない。AppDelegate 側に残るコードは: (1) `binder = CoordinatorBinder(...)` + `binder?.bind()` の数行、(2) `gazeController.statusItemCenterProvider` の設定（NSStatusItem の画面座標取得、視線追跡の必須結線）。いずれも **コードレビュー（目視）で十分カバー可能**。**注意: `activeBubble` と `ephemeralBubble` は同一の `BubblePresenting` 型のため、引数の入れ替えはコンパイル時に検出できない。これは型安全ではなく手動レビュー依存のリスクである。** CoordinatorBinder の init パラメータ名（`activeBubble:` / `ephemeralBubble:`）と AppDelegate 側のプロパティ名（`bubbleWindow` / `ephemeralBubbleWindow`）の対応で軽減するが、完全な防止策ではない。statusItemCenterProvider はテストでは固定値 `{ CGPoint(x: 500, y: 300) }` を直接設定するため、AppDelegate 側の実 NSStatusItem 座標取得ロジックは自動テスト外。将来的にはアプリ起動後の GUI smoke test で補完可能 |
| BubblePresenting プロトコル追加の影響 | BubbleWindow の既存 show/dismiss シグネチャがそのまま準拠する。メソッド追加なし |
| auto-transition の timer が CI で不安定 | DI パラメータで 0.3 秒に短縮 + XCTestExpectation(timeout: 2.0) で十分なマージン確保 |
| GazeController の polling タイマーが CI で不安定 | MockAXProvider + pollInterval 0.1秒 + statusItemCenterProvider 固定値設定で決定論的に制御 |
| BlinkController のランダム間隔がテストで非決定的 | randomSource を { 0.0 } で注入（最短間隔 0.1秒）、intervalRange を 0.1...0.2 に設定 |
| ClabotchEyeView の triggerBlink が 150ms タイマーに依存 | XCTestExpectation + asyncAfter(0.25) で待機 |
| onEphemeralDone の dispatch 戦略変更 | 現実装は同期呼び出し（逸脱 #4）だが、テストは async-tolerant パターン（observable state ポーリング）を使用し、将来 main.async に戻っても機能する |
| 否定テスト（F2, D3, H2, H3）の偽陽性 | XCTestExpectation(isInverted: true) + timeout 0.5秒（複数 interval 相当）で確実に検証 |
| headless CI での timer coalescing | テスト用タイマー値を保守的に設定（0.1〜0.5秒範囲）。waitForExpectations に十分な timeout（2.0秒） |
| onPhaseChanged の dispatch 戦略変更 | async-tolerant パターンにより sync / async どちらでもテストが機能する |
