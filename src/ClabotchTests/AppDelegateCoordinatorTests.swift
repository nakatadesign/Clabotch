@testable import Clabotch
import XCTest

/// CoordinatorBinder の変換メソッドのテスト。
/// Phase → GazeOverride / BlinkEnabled / BubbleText の対応表を検証する。
@MainActor
final class AppDelegateCoordinatorTests: XCTestCase {

    /// bubbleText テスト用: セッション 0 件の binder インスタンス
    private func makeBinderWithNoSessions() -> CoordinatorBinder {
        let sm = StateMachine()
        let gc = GazeController(axProvider: MockAXProvider(), workspaceProvider: MockWorkspaceProvider(), pollInterval: 1)
        let bc = BlinkController()
        return CoordinatorBinder(
            stateMachine: sm,
            gazeController: gc,
            blinkController: bc,
            eyeView: nil,
            activeBubble: BubbleSpy(),
            ephemeralBubble: BubbleSpy(),
            anchorProvider: { nil }
        )
    }

    // MARK: - gazeOverride(for:)

    func testGazeOverrideForIdleNone() {
        let override = CoordinatorBinder.gazeOverride(for: .idle)
        XCTAssertEqual(override, .none)
    }

    func testGazeOverrideForThinkingNone() {
        let override = CoordinatorBinder.gazeOverride(for: .thinking)
        XCTAssertEqual(override, .none)
    }

    func testGazeOverrideForWorkingNone() {
        let override = CoordinatorBinder.gazeOverride(for: .working(toolName: "Bash"))
        XCTAssertEqual(override, .none)
    }

    func testGazeOverrideForDoneNone() {
        let override = CoordinatorBinder.gazeOverride(for: .done(elapsedMs: 1000))
        XCTAssertEqual(override, .none)
    }

    func testGazeOverrideForErrorFixed() {
        let override = CoordinatorBinder.gazeOverride(for: .error(toolName: "test", message: "err"))
        XCTAssertEqual(override, .fixed(frame: .f01_center, reason: .mascotStateOverride))
    }

    func testGazeOverrideForSleepingFixed() {
        let override = CoordinatorBinder.gazeOverride(for: .sleeping)
        XCTAssertEqual(override, .fixed(frame: .f01_center, reason: .mascotStateOverride))
    }

    // MARK: - isBlinkEnabled(for:)

    func testIsBlinkEnabledMapping() {
        // 通常 phase → true
        XCTAssertTrue(CoordinatorBinder.isBlinkEnabled(for: .idle))
        XCTAssertTrue(CoordinatorBinder.isBlinkEnabled(for: .thinking))
        XCTAssertTrue(CoordinatorBinder.isBlinkEnabled(for: .working(toolName: "bash")))
        XCTAssertTrue(CoordinatorBinder.isBlinkEnabled(for: .done(elapsedMs: 1000)))

        // 停止 phase → false
        XCTAssertFalse(CoordinatorBinder.isBlinkEnabled(for: .error(toolName: "test", message: nil)))
        XCTAssertFalse(CoordinatorBinder.isBlinkEnabled(for: .sleeping))
    }

    // MARK: - bubbleText(for:) — セッション 0 件（サフィックスなし）

    func testBubbleTextThinking() {
        let binder = makeBinderWithNoSessions()
        XCTAssertEqual(binder.bubbleText(for: .thinking), "考えてます...")
    }

    func testBubbleTextDoneWithTime() {
        let binder = makeBinderWithNoSessions()
        XCTAssertEqual(binder.bubbleText(for: .done(elapsedMs: 222000)), "完了！(3分42秒)")
    }

    func testBubbleTextDoneNoTime() {
        let binder = makeBinderWithNoSessions()
        XCTAssertEqual(binder.bubbleText(for: .done(elapsedMs: 0)), "完了！")
    }

    func testBubbleTextErrorFixedMessage() {
        let binder = makeBinderWithNoSessions()
        // v11 §6: error は固定文言。error_message は表示しない (§13.6)
        XCTAssertEqual(binder.bubbleText(for: .error(toolName: "Bash", message: "some detail")), "エラーが出ました…")
        XCTAssertEqual(binder.bubbleText(for: .error(toolName: "Bash", message: nil)), "エラーが出ました…")
    }

    func testBubbleTextWorking() {
        let binder = makeBinderWithNoSessions()
        XCTAssertEqual(binder.bubbleText(for: .working(toolName: "Bash")), "作業中... (Bash)")
    }

    func testBubbleTextIdleNil() {
        let binder = makeBinderWithNoSessions()
        XCTAssertNil(binder.bubbleText(for: .idle))
        XCTAssertNil(binder.bubbleText(for: .sleeping))
    }

    // MARK: - debugName（MascotPhase extension）

    func testDebugNameIncludesAssociatedValues() {
        XCTAssertEqual(MascotPhase.idle.debugName, "idle")
        XCTAssertEqual(MascotPhase.thinking.debugName, "thinking")
        XCTAssertEqual(MascotPhase.working(toolName: "Bash").debugName, "working(Bash)")
        XCTAssertEqual(MascotPhase.done(elapsedMs: 99999).debugName, "done(99999ms)")
        XCTAssertEqual(MascotPhase.error(toolName: "Read", message: "err").debugName, "error(Read)")
        XCTAssertEqual(MascotPhase.sleeping.debugName, "sleeping")
    }

    func testDebugNameDoesNotLeakErrorMessage() {
        // error の debugName には toolName を含むが、error message は含まない
        let name = MascotPhase.error(toolName: "Bash", message: "token=abc123").debugName
        XCTAssertFalse(name.contains("token"))
        XCTAssertFalse(name.contains("abc123"))
        XCTAssertEqual(name, "error(Bash)")
    }

    // MARK: - formatElapsedTime

    func testFormatElapsedTime() {
        XCTAssertEqual(CoordinatorBinder.formatElapsedTime(222000), "3分42秒")
        XCTAssertEqual(CoordinatorBinder.formatElapsedTime(5000), "5秒")
        XCTAssertEqual(CoordinatorBinder.formatElapsedTime(60000), "1分0秒")
        XCTAssertEqual(CoordinatorBinder.formatElapsedTime(0), "0秒")
    }
}
