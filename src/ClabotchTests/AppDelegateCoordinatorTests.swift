@testable import Clabotch
import XCTest

/// AppDelegate の static 変換メソッドのテスト。
/// Phase → GazeOverride / BlinkEnabled の対応表を検証する。
final class AppDelegateCoordinatorTests: XCTestCase {

    // MARK: - gazeOverride(for:)

    func testGazeOverrideForIdleFixed() {
        let override = AppDelegate.gazeOverride(for: .idle)
        XCTAssertEqual(override, .fixed(frame: .f02_rightDown, reason: .mascotStateOverride))
    }

    func testGazeOverrideForThinkingNone() {
        let override = AppDelegate.gazeOverride(for: .thinking)
        XCTAssertEqual(override, .none)
    }

    func testGazeOverrideForErrorFixed() {
        let override = AppDelegate.gazeOverride(for: .error(toolName: "test", message: "err"))
        XCTAssertEqual(override, .fixed(frame: .f01_center, reason: .mascotStateOverride))
    }

    // MARK: - isBlinkEnabled(for:)

    func testIsBlinkEnabledMapping() {
        // 通常 phase → true
        XCTAssertTrue(AppDelegate.isBlinkEnabled(for: .idle))
        XCTAssertTrue(AppDelegate.isBlinkEnabled(for: .thinking))
        XCTAssertTrue(AppDelegate.isBlinkEnabled(for: .working(toolName: "bash")))
        XCTAssertTrue(AppDelegate.isBlinkEnabled(for: .done(elapsedMs: 1000)))

        // 停止 phase → false
        XCTAssertFalse(AppDelegate.isBlinkEnabled(for: .error(toolName: "test", message: nil)))
        XCTAssertFalse(AppDelegate.isBlinkEnabled(for: .sleeping))
    }

    // MARK: - bubbleText(for:)

    func testBubbleTextThinking() {
        XCTAssertEqual(AppDelegate.bubbleText(for: .thinking), "考えてます...")
    }

    func testBubbleTextDoneWithTime() {
        XCTAssertEqual(AppDelegate.bubbleText(for: .done(elapsedMs: 222000)), "完了！(3分42秒)")
    }

    func testBubbleTextDoneNoTime() {
        XCTAssertEqual(AppDelegate.bubbleText(for: .done(elapsedMs: 0)), "完了！")
    }

    func testBubbleTextErrorFixedMessage() {
        // v11 §6: error は固定文言。error_message は表示しない (§13.6)
        XCTAssertEqual(AppDelegate.bubbleText(for: .error(toolName: "Bash", message: "some detail")), "エラーが出ました…")
        XCTAssertEqual(AppDelegate.bubbleText(for: .error(toolName: "Bash", message: nil)), "エラーが出ました…")
    }

    func testBubbleTextIdleNil() {
        XCTAssertNil(AppDelegate.bubbleText(for: .idle))
        XCTAssertNil(AppDelegate.bubbleText(for: .sleeping))
    }

    // MARK: - formatElapsedTime

    func testFormatElapsedTime() {
        XCTAssertEqual(AppDelegate.formatElapsedTime(222000), "3分42秒")
        XCTAssertEqual(AppDelegate.formatElapsedTime(5000), "5秒")
        XCTAssertEqual(AppDelegate.formatElapsedTime(60000), "1分0秒")
        XCTAssertEqual(AppDelegate.formatElapsedTime(0), "0秒")
    }
}
