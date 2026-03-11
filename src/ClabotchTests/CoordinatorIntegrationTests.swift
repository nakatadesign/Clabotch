@testable import Clabotch
import XCTest

/// CoordinatorBinder.bind() による StateMachine → 下流コンポーネント連携の統合テスト。
/// テストは CoordinatorBinder.bind() が設定する実プロダクション callback を通して検証する。
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

        gazeController.statusItemCenterProvider = { CGPoint(x: 500, y: 300) }

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

        UserDefaults.standard.removeObject(forKey: "didRequestAccessibility")

        // 起動順は AppDelegate と同じ
        stateMachine.start()
        gazeController.startPolling()
    }

    override func tearDown() {
        activeBubbleSpy.dismiss()
        ephemeralBubbleSpy.dismiss()
        blinkController.setBlinking(enabled: false)
        gazeController.stopPolling()
        UserDefaults.standard.removeObject(forKey: "didRequestAccessibility")
        super.tearDown()
    }

    // MARK: - ヘルパー

    /// observable state をポーリングして待機する。
    private func waitForCondition(
        timeout: TimeInterval = 2.0,
        description: String,
        condition: @escaping () -> Bool
    ) {
        let exp = expectation(description: description)
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            if condition() {
                timer.invalidate()
                exp.fulfill()
            }
        }
        waitForExpectations(timeout: timeout) { _ in timer.invalidate() }
    }

    /// 否定テスト: condition が true に**ならない**ことを検証する。
    private func waitForNoChange(
        timeout: TimeInterval = 0.5,
        description: String,
        condition: @escaping () -> Bool
    ) {
        let exp = expectation(description: description)
        exp.isInverted = true
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            if condition() {
                timer.invalidate()
                exp.fulfill()
            }
        }
        waitForExpectations(timeout: timeout) { _ in timer.invalidate() }
    }

    // MARK: - A. Full Session Flow

    func testA1SessionStartSetsThinkingPhase() {
        stateMachine.handle(event: .sessionStart(sessionID: "s1"))

        waitForCondition(description: "bubble shows thinking text") {
            self.activeBubbleSpy.lastText == "考えてます..."
        }

        XCTAssertEqual(blinkController.isBlinking, true)
        XCTAssertEqual(eyeView.faceColor, ClabotchEyeView.Palette.faceNormal)
        XCTAssertFalse(eyeView.showErrorX)
        XCTAssertFalse(eyeView.showSurprise)
    }

    func testA2ToolStartSetsWorkingPhase() {
        stateMachine.handle(event: .sessionStart(sessionID: "s1"))
        stateMachine.handle(event: .toolStart(sessionID: "s1", toolName: "Bash"))

        waitForCondition(description: "bubble shows working text") {
            self.activeBubbleSpy.lastText == "Bash 実行中..."
        }
    }

    func testA3ToolEndSuccessReturnsToThinking() {
        stateMachine.handle(event: .sessionStart(sessionID: "s1"))
        stateMachine.handle(event: .toolStart(sessionID: "s1", toolName: "Bash"))
        stateMachine.handle(event: .toolEnd(sessionID: "s1", toolName: "Bash", durationMs: 0, isError: false, errorMessage: nil))

        waitForCondition(description: "bubble shows thinking text") {
            self.activeBubbleSpy.lastText == "考えてます..."
        }
    }

    func testA4SessionDoneWithElapsedTime() {
        stateMachine.handle(event: .sessionStart(sessionID: "s1"))
        stateMachine.handle(event: .sessionDone(sessionID: "s1", elapsedMs: 222000))

        waitForCondition(description: "bubble shows done text") {
            self.activeBubbleSpy.lastText == "完了！(3分42秒)"
        }

        XCTAssertEqual(eyeView.showSurprise, true)
        XCTAssertEqual(
            gazeController.mode,
            .fixed(.f02_rightDown, reason: .mascotStateOverride)
        )
    }

    func testA5SessionDoneZeroMsShowsCompletionOnly() {
        stateMachine.handle(event: .sessionStart(sessionID: "s1"))
        stateMachine.handle(event: .sessionDone(sessionID: "s1", elapsedMs: 0))

        waitForCondition(description: "bubble shows done text without time") {
            self.activeBubbleSpy.lastText == "完了！"
        }
    }

    func testA6DoneAutoTransitionToIdle() {
        stateMachine.handle(event: .sessionStart(sessionID: "s1"))
        stateMachine.handle(event: .sessionDone(sessionID: "s1", elapsedMs: 1000))

        waitForCondition(description: "auto-transition to idle") {
            self.stateMachine.displayPhase == .idle
        }

        XCTAssertFalse(eyeView.showSurprise)
        // idle → bubbleText==nil → dismiss
        XCTAssertFalse(activeBubbleSpy.isShowing)
    }

    // MARK: - B. Error Flow

    func testB1ToolEndWithErrorSetsErrorPhase() {
        stateMachine.handle(event: .sessionStart(sessionID: "s1"))
        stateMachine.handle(event: .toolStart(sessionID: "s1", toolName: "Bash"))
        stateMachine.handle(event: .toolEnd(sessionID: "s1", toolName: "Bash", durationMs: 0, isError: true, errorMessage: "fail"))

        waitForCondition(description: "bubble shows error text") {
            self.activeBubbleSpy.lastText == "エラーが出ました…"
        }

        XCTAssertEqual(gazeController.mode, .fixed(.f01_center, reason: .mascotStateOverride))
        XCTAssertFalse(blinkController.isBlinking)
        XCTAssertTrue(eyeView.showErrorX)
    }

    func testB2ErrorAutoTransitionToThinking() {
        stateMachine.handle(event: .sessionStart(sessionID: "s1"))
        stateMachine.handle(event: .toolStart(sessionID: "s1", toolName: "Bash"))
        stateMachine.handle(event: .toolEnd(sessionID: "s1", toolName: "Bash", durationMs: 0, isError: true, errorMessage: "fail"))

        waitForCondition(description: "auto-transition to thinking") {
            self.stateMachine.displayPhase == .thinking
        }

        XCTAssertFalse(eyeView.showErrorX)
        XCTAssertEqual(eyeView.faceColor, ClabotchEyeView.Palette.faceNormal)
        XCTAssertEqual(activeBubbleSpy.lastText, "考えてます...")
    }

    // MARK: - C. Sleeping Flow

    func testC1SleepingPhaseAfterThreshold() {
        // setUp で stateMachine.start() → idle。sleepThreshold=0.5秒
        waitForCondition(description: "sleeping after threshold") {
            self.stateMachine.displayPhase == .sleeping
        }

        XCTAssertEqual(gazeController.mode, .fixed(.f01_center, reason: .mascotStateOverride))
        XCTAssertFalse(blinkController.isBlinking)
        XCTAssertTrue(eyeView.isBlinkClosed)
        XCTAssertEqual(eyeView.faceColor, ClabotchEyeView.Palette.faceSleep)
        XCTAssertNil(activeBubbleSpy.lastText)
    }

    func testC2SleepingCancelledBySessionStart() {
        waitForCondition(description: "sleeping") {
            self.stateMachine.displayPhase == .sleeping
        }

        stateMachine.handle(event: .sessionStart(sessionID: "s1"))

        waitForCondition(description: "thinking after wake") {
            self.stateMachine.displayPhase == .thinking
        }

        XCTAssertFalse(eyeView.isBlinkClosed)
    }

    // MARK: - D. Ephemeral Done

    func testD1EphemeralDoneShowsOnSeparateBubble() {
        // active session を確立
        stateMachine.handle(event: .sessionStart(sessionID: "s1"))
        let activeCountBefore = activeBubbleSpy.showCalls.count

        // foreign session done
        stateMachine.handle(event: .sessionDone(sessionID: "s-foreign", elapsedMs: 72000))

        waitForCondition(description: "ephemeral bubble shows") {
            self.ephemeralBubbleSpy.showCalls.count > 0
        }

        let call = ephemeralBubbleSpy.showCalls.last!
        XCTAssertEqual(call.text, "別セッション完了 (1分12秒)")
        XCTAssertEqual(call.duration, 2.0)
        // active bubble は変化なし
        XCTAssertEqual(activeBubbleSpy.showCalls.count, activeCountBefore)
    }

    func testD2EphemeralDoneWithActivePhase() {
        stateMachine.handle(event: .sessionStart(sessionID: "s1"))
        stateMachine.handle(event: .toolStart(sessionID: "s1", toolName: "Bash"))

        let lastText = activeBubbleSpy.lastText

        stateMachine.handle(event: .sessionDone(sessionID: "s-foreign", elapsedMs: 5000))

        waitForCondition(description: "ephemeral bubble shows") {
            self.ephemeralBubbleSpy.showCalls.count > 0
        }

        // active bubble のテキストは working のまま
        XCTAssertEqual(activeBubbleSpy.lastText, lastText)
    }

    func testD3ForeignDoneZeroMsSilentDrop() {
        stateMachine.handle(event: .sessionStart(sessionID: "s1"))

        let countBefore = ephemeralBubbleSpy.showCalls.count
        stateMachine.handle(event: .sessionDone(sessionID: "s-foreign", elapsedMs: 0))

        waitForNoChange(description: "ephemeral bubble NOT called") {
            self.ephemeralBubbleSpy.showCalls.count > countBefore
        }
    }

    // MARK: - E. GazeController → EyeView

    func testE1GazeTrackingPropagatesFrameToEyeView() {
        // thinking phase → override=none
        stateMachine.handle(event: .sessionStart(sessionID: "s1"))

        // mock 設定: ターミナルが左下にある
        mockAX.isTrusted = true
        mockWorkspace.bundleIdentifier = "com.apple.Terminal"
        mockWorkspace.pid = 12345
        mockAX.terminalCenter = CGPoint(x: 100, y: 500)

        // polling で gazeFrame が更新されるのを待つ
        waitForCondition(description: "eyeView gazeFrame changes") {
            self.eyeView.gazeFrame != .f02_rightDown
        }
    }

    func testE2GazeOverrideFixedSetsFrameImmediately() {
        gazeController.setOverride(.fixed(frame: .f01_center, reason: .mascotStateOverride))

        XCTAssertEqual(gazeController.gazeFrame, .f01_center)
        XCTAssertEqual(eyeView.gazeFrame, .f01_center)
    }

    // MARK: - F. BlinkController → EyeView

    func testF1BlinkCallbackTriggersEyeViewBlink() {
        // setUp で blinkController.isBlinking=true（idle → setBlinking(true)）
        // randomSource={0.0} + intervalRange 0.1...0.2 → 0.1秒後に onBlink 発火
        waitForCondition(description: "eyeView blink") {
            self.eyeView.isBlinkClosed
        }
    }

    func testF2BlinkDisabledStopsCallback() {
        // sleeping phase を使用（auto-transition がないため安定して検証可能）
        waitForCondition(description: "sleeping") {
            self.stateMachine.displayPhase == .sleeping
        }

        XCTAssertFalse(blinkController.isBlinking)

        // sleeping → sessionStart で blink 再開を確認
        stateMachine.handle(event: .sessionStart(sessionID: "s1"))
        XCTAssertTrue(blinkController.isBlinking)

        // error phase → blink 停止
        stateMachine.handle(event: .toolStart(sessionID: "s1", toolName: "Bash"))
        stateMachine.handle(event: .toolEnd(sessionID: "s1", toolName: "Bash", durationMs: 0, isError: true, errorMessage: "fail"))

        XCTAssertFalse(blinkController.isBlinking)
        // error auto-transition（0.3秒後 → thinking）を待ってから blink 再開を確認
        // → blink disabled/enabled の切り替えが正しく連携していることの証明
        waitForCondition(description: "auto-transition to thinking re-enables blink") {
            self.blinkController.isBlinking == true
        }
    }

    // MARK: - G. 起動順保証

    func testG1StartupOrderSetsOverrideBeforePolling() {
        // 個別に start/startPolling を制御するため、新しいインスタンスを作成
        let sm = StateMachine(sleepThreshold: 300)
        let gc = GazeController(
            axProvider: mockAX,
            workspaceProvider: mockWorkspace,
            pollInterval: 0.1
        )
        let bc = BlinkController()
        let ev = ClabotchEyeView(frame: NSRect(x: 0, y: 0, width: 22, height: 14))
        let ab = BubbleSpy()
        let eb = BubbleSpy()

        let testBinder = CoordinatorBinder(
            stateMachine: sm,
            gazeController: gc,
            blinkController: bc,
            eyeView: ev,
            activeBubble: ab,
            ephemeralBubble: eb,
            anchorProvider: { CGPoint(x: 100, y: 100) }
        )
        testBinder.bind()

        // GazeController 初期値: .fixed(.f02_rightDown, reason: .terminalNotFound)
        XCTAssertEqual(gc.mode, .fixed(.f02_rightDown, reason: .terminalNotFound))

        // start() → onPhaseChanged(.idle) → setOverride(.fixed(.f02_rightDown, .mascotStateOverride))
        sm.start()

        // reason が .mascotStateOverride に変わったことで start() 経由の setOverride を証明
        XCTAssertEqual(gc.mode, .fixed(.f02_rightDown, reason: .mascotStateOverride))

        // startPolling() はまだ呼ばれていない
        gc.startPolling()
        gc.stopPolling()
        bc.setBlinking(enabled: false)
    }

    // MARK: - H. テスト独立性・Cleanup・No-op

    func testH1CleanupStopsAllTimers() {
        // thinking phase に遷移（override=none）
        stateMachine.handle(event: .sessionStart(sessionID: "s1"))

        mockAX.isTrusted = true
        mockWorkspace.bundleIdentifier = "com.apple.Terminal"
        mockWorkspace.pid = 12345
        mockAX.terminalCenter = CGPoint(x: 100, y: 500)

        // polling で gazeFrame が変化することを確認
        waitForCondition(description: "gazeFrame changes via polling") {
            self.eyeView.gazeFrame != .f02_rightDown
        }

        let frameAfterPolling = eyeView.gazeFrame

        // cleanup
        gazeController.stopPolling()
        blinkController.setBlinking(enabled: false)
        activeBubbleSpy.dismiss()
        ephemeralBubbleSpy.dismiss()

        // ターミナル座標を変更
        mockAX.terminalCenter = CGPoint(x: 900, y: 100)

        // gazeFrame が変化しないことを検証（pollTimer 停止済み）
        waitForNoChange(timeout: 0.3, description: "no polling after stop") {
            self.eyeView.gazeFrame != frameAfterPolling
        }

        XCTAssertFalse(blinkController.isBlinking)
    }

    func testH2ForeignSessionStartNoFanOut() {
        // active session を確立
        stateMachine.handle(event: .sessionStart(sessionID: "s1"))
        let countBefore = activeBubbleSpy.showCalls.count

        // foreign session_start
        stateMachine.handle(event: .sessionStart(sessionID: "s-foreign"))

        waitForNoChange(description: "no additional fan-out") {
            self.activeBubbleSpy.showCalls.count > countBefore
        }
    }

    func testH3DuplicateSessionStartNoFanOut() {
        stateMachine.handle(event: .sessionStart(sessionID: "s1"))
        let countAfterFirst = activeBubbleSpy.showCalls.count

        // 同一 sessionID で 2 回目
        stateMachine.handle(event: .sessionStart(sessionID: "s1"))

        waitForNoChange(description: "no duplicate fan-out") {
            self.activeBubbleSpy.showCalls.count > countAfterFirst
        }
    }
}
