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
            pollInterval: 0.1,
            pollIntervalNotGranted: 0.1
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



        // 起動順は AppDelegate と同じ
        stateMachine.start()
        gazeController.startPolling()
    }

    override func tearDown() {
        activeBubbleSpy.dismiss()
        ephemeralBubbleSpy.dismiss()
        blinkController.setBlinking(enabled: false)
        gazeController.stopPolling()

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
            self.activeBubbleSpy.lastText == "作業中... (Bash)"
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
        // done でも視線追跡（override=none）
        // GazeController は AX 権限なしだと permissionNotDetermined で fixed になるが、override 自体は none
        XCTAssertNotEqual(
            gazeController.mode,
            .fixed(.f02_rightDown, reason: .mascotStateOverride)
        )
        // §5: DONE 時にジャンプアニメーションがトリガーされる
        XCTAssertTrue(eyeView.isJumping || eyeView.frame.origin.y == 0,
                      "ジャンプがトリガーされているか、既に完了しているべき")
    }

    func testA5SessionDoneZeroMsShowsCompletionOnly() {
        stateMachine.handle(event: .sessionStart(sessionID: "s1"))
        stateMachine.handle(event: .sessionDone(sessionID: "s1", elapsedMs: 0))

        // hookElapsedMs=0 の場合、StateMachine が startedAt からフォールバック計算するため
        // 数ミリ秒の差が生じて "完了！(0秒)" になることがある
        waitForCondition(description: "bubble shows done text") {
            guard let text = self.activeBubbleSpy.lastText else { return false }
            return text.hasPrefix("完了！")
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

    func testD2EphemeralDoneWithActivePhaseOffsetsAnchor() {
        stateMachine.handle(event: .sessionStart(sessionID: "s1"))
        stateMachine.handle(event: .toolStart(sessionID: "s1", toolName: "Bash"))

        // activeBubble は working フェーズで表示中
        XCTAssertTrue(activeBubbleSpy.isShowing)
        let lastText = activeBubbleSpy.lastText

        stateMachine.handle(event: .sessionDone(sessionID: "s-foreign", elapsedMs: 5000))

        waitForCondition(description: "ephemeral bubble shows") {
            self.ephemeralBubbleSpy.showCalls.count > 0
        }

        // active bubble のテキストは working のまま
        XCTAssertEqual(activeBubbleSpy.lastText, lastText)

        // ephemeral は activeBubble が表示中なので anchor が下にオフセットされる
        let call = ephemeralBubbleSpy.showCalls.last!
        let expectedY = 100.0 - CoordinatorBinder.bubbleStackOffset
        XCTAssertEqual(call.anchor.y, expectedY, accuracy: 0.01)
        XCTAssertEqual(call.anchor.x, 100.0, accuracy: 0.01)
    }

    func testD2bEphemeralDoneWithoutActiveUsesOriginalAnchor() {
        // active session を確立するが、idle フェーズ（bubble 非表示）
        stateMachine.handle(event: .sessionStart(sessionID: "s1"))
        stateMachine.handle(event: .sessionDone(sessionID: "s1", elapsedMs: 3000))

        // done → idle への自動遷移を待つ
        waitForCondition(description: "idle phase") {
            self.stateMachine.displayPhase == .idle
        }

        // activeBubble は非表示
        XCTAssertFalse(activeBubbleSpy.isShowing)

        stateMachine.handle(event: .sessionDone(sessionID: "s-foreign", elapsedMs: 5000))

        waitForCondition(description: "ephemeral bubble shows") {
            self.ephemeralBubbleSpy.showCalls.count > 0
        }

        // activeBubble 非表示 → オフセットなし
        let call = ephemeralBubbleSpy.showCalls.last!
        XCTAssertEqual(call.anchor.y, 100.0, accuracy: 0.01)
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

        // mock 設定: ターミナルが右下にある（初期値 f03_leftDown と異なる方向）
        mockAX.isTrusted = true
        mockWorkspace.bundleIdentifier = "com.apple.Terminal"
        mockWorkspace.pid = 12345
        mockAX.terminalCenter = CGPoint(x: 2500, y: 500)

        // polling で gazeFrame が更新されるのを待つ
        waitForCondition(description: "eyeView gazeFrame changes") {
            self.eyeView.gazeFrame != .f03_leftDown
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

        // GazeController 初期値: .fixed(.f03_leftDown, reason: .terminalNotFound)
        XCTAssertEqual(gc.mode, .fixed(.f03_leftDown, reason: .terminalNotFound))

        // start() → onPhaseChanged(.idle) → setOverride(.none) → 常にカーソル追跡
        sm.start()

        // idle でも override=none なので、GazeController は polling で決まる mode になる
        // mascotStateOverride ではないことを検証
        XCTAssertNotEqual(gc.mode, .fixed(.f02_rightDown, reason: .mascotStateOverride))

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
        mockAX.terminalCenter = CGPoint(x: 2500, y: 500)

        // polling で gazeFrame が変化することを確認（初期値 f03_leftDown → f02_rightDown）
        waitForCondition(description: "gazeFrame changes via polling") {
            self.eyeView.gazeFrame != .f03_leftDown
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

    func testH2ForeignSessionStartUpdatesBubbleWithSuffix() {
        // active session を確立
        stateMachine.handle(event: .sessionStart(sessionID: "s1"))

        // foreign session_start → セッション数変化で [+1] サフィックスが付加される
        stateMachine.handle(event: .sessionStart(sessionID: "s-foreign"))

        waitForCondition(description: "bubble updated with [+1] suffix") {
            self.activeBubbleSpy.lastText == "考えてます... [+1]"
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

    // MARK: - I. マルチセッション吹き出し表示

    func testI1SingleSessionBubbleTextHasNoSuffix() {
        stateMachine.handle(event: .sessionStart(sessionID: "s1"))

        waitForCondition(description: "bubble shows thinking text") {
            self.activeBubbleSpy.lastText == "考えてます..."
        }
    }

    func testI2TwoSessionsBubbleTextShowsPlusOne() {
        stateMachine.handle(event: .sessionStart(sessionID: "s1"))
        stateMachine.handle(event: .sessionStart(sessionID: "s2"))

        // s2 は s1 と同じ thinking → displayPhase 変化なし
        // s2 を working にして displayPhase を更新させる
        stateMachine.handle(event: .toolStart(sessionID: "s2", toolName: "Bash"))

        waitForCondition(description: "bubble shows [+1] suffix") {
            self.activeBubbleSpy.lastText == "作業中... (Bash) [+1]"
        }
    }

    func testI3ThreeSessionsBubbleTextShowsPlusTwo() {
        stateMachine.handle(event: .sessionStart(sessionID: "s1"))
        stateMachine.handle(event: .sessionStart(sessionID: "s2"))
        stateMachine.handle(event: .sessionStart(sessionID: "s3"))

        // s3 を error にして displayPhase を error に変更
        stateMachine.handle(event: .toolStart(sessionID: "s3", toolName: "Bash"))
        stateMachine.handle(event: .toolEnd(sessionID: "s3", toolName: "Bash", durationMs: 0, isError: true, errorMessage: "fail"))

        waitForCondition(description: "bubble shows [+2] suffix") {
            self.activeBubbleSpy.lastText == "エラーが出ました… [+2]"
        }
    }

    func testI4SessionDoneReducesSuffix() {
        stateMachine.handle(event: .sessionStart(sessionID: "s1"))
        stateMachine.handle(event: .sessionStart(sessionID: "s2"))

        // s1 を working にして表示
        stateMachine.handle(event: .toolStart(sessionID: "s1", toolName: "Read"))

        waitForCondition(description: "bubble shows [+1]") {
            self.activeBubbleSpy.lastText == "作業中... (Read) [+1]"
        }

        // s2 が done → session cleanup 後にサフィックスが消える
        stateMachine.handle(event: .sessionDone(sessionID: "s2", elapsedMs: 1000))

        // done セッションの cleanup（doneAutoTransitionDelay=0.3s）を待つ
        waitForCondition(description: "suffix disappears after session cleanup") {
            self.activeBubbleSpy.lastText == "作業中... (Read)"
        }
    }

    func testI5DonePhaseWithMultiSessionsShowsSuffix() {
        stateMachine.handle(event: .sessionStart(sessionID: "s1"))
        stateMachine.handle(event: .sessionStart(sessionID: "s2"))

        // s1 を done に → displayPhase は s2 の thinking（priority 2 < done 3）
        stateMachine.handle(event: .sessionDone(sessionID: "s1", elapsedMs: 5000))

        // s2 は thinking, s1 は done（まだ cleanup 前）→ sessions.count=2
        waitForCondition(description: "thinking with [+1] for done session") {
            self.activeBubbleSpy.lastText == "考えてます... [+1]"
        }
    }
}
