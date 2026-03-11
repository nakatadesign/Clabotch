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
}
