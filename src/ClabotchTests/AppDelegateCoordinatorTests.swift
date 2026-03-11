@testable import Clabotch
import XCTest

/// CoordinatorBinder の static 変換メソッドのテスト。
/// Phase → GazeOverride / BlinkEnabled の対応表を検証する。
final class AppDelegateCoordinatorTests: XCTestCase {

    // MARK: - gazeOverride(for:)

    func testGazeOverrideForIdleFixed() {
        let override = CoordinatorBinder.gazeOverride(for: .idle)
        XCTAssertEqual(override, .fixed(frame: .f02_rightDown, reason: .mascotStateOverride))
    }

    func testGazeOverrideForThinkingNone() {
        let override = CoordinatorBinder.gazeOverride(for: .thinking)
        XCTAssertEqual(override, .none)
    }

    func testGazeOverrideForWorkingNone() {
        let override = CoordinatorBinder.gazeOverride(for: .working(toolName: "Bash"))
        XCTAssertEqual(override, .none)
    }

    func testGazeOverrideForDoneFixed() {
        let override = CoordinatorBinder.gazeOverride(for: .done(elapsedMs: 1000))
        XCTAssertEqual(override, .fixed(frame: .f02_rightDown, reason: .mascotStateOverride))
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

    // MARK: - bubbleText(for:)

    func testBubbleTextThinking() {
        XCTAssertEqual(CoordinatorBinder.bubbleText(for: .thinking), "考えてます...")
    }

    func testBubbleTextDoneWithTime() {
        XCTAssertEqual(CoordinatorBinder.bubbleText(for: .done(elapsedMs: 222000)), "完了！(3分42秒)")
    }

    func testBubbleTextDoneNoTime() {
        XCTAssertEqual(CoordinatorBinder.bubbleText(for: .done(elapsedMs: 0)), "完了！")
    }

    func testBubbleTextErrorFixedMessage() {
        // v11 §6: error は固定文言。error_message は表示しない (§13.6)
        XCTAssertEqual(CoordinatorBinder.bubbleText(for: .error(toolName: "Bash", message: "some detail")), "エラーが出ました…")
        XCTAssertEqual(CoordinatorBinder.bubbleText(for: .error(toolName: "Bash", message: nil)), "エラーが出ました…")
    }

    func testBubbleTextWorking() {
        XCTAssertEqual(CoordinatorBinder.bubbleText(for: .working(toolName: "Bash")), "Bash 実行中...")
    }

    func testBubbleTextIdleNil() {
        XCTAssertNil(CoordinatorBinder.bubbleText(for: .idle))
        XCTAssertNil(CoordinatorBinder.bubbleText(for: .sleeping))
    }

    // MARK: - formatElapsedTime

    func testFormatElapsedTime() {
        XCTAssertEqual(CoordinatorBinder.formatElapsedTime(222000), "3分42秒")
        XCTAssertEqual(CoordinatorBinder.formatElapsedTime(5000), "5秒")
        XCTAssertEqual(CoordinatorBinder.formatElapsedTime(60000), "1分0秒")
        XCTAssertEqual(CoordinatorBinder.formatElapsedTime(0), "0秒")
    }
}
