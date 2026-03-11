@testable import Clabotch
import XCTest

/// BubbleWindow のテスト。
/// windowFactory に nil を返すスタブを注入し、ヘッドレス環境でも
/// show/dismiss/auto-dismiss ライフサイクルを安全に検証する。
final class BubbleWindowTests: XCTestCase {

    /// ヘッドレス対応: NSWindow を生成せず nil を返すファクトリを注入
    private func makeHeadlessSUT() -> BubbleWindow {
        let sut = BubbleWindow()
        sut.windowFactory = { _, _ in nil }
        return sut
    }

    /// タイマーを手動制御するヘルパー
    private func makeManualTimerSUT() -> (BubbleWindow, () -> Void) {
        let sut = makeHeadlessSUT()
        var capturedHandler: (() -> Void)?
        sut.timerScheduler = { _, handler in
            capturedHandler = handler
            return Timer()  // 発火しないダミー
        }
        let fire: () -> Void = { capturedHandler?() }
        return (sut, fire)
    }

    // MARK: - 初期状態

    func testInitialState() {
        let sut = BubbleWindow()
        XCTAssertFalse(sut.isShowing)
        XCTAssertNil(sut.lastText)
        XCTAssertNil(sut.dismissTimer)
    }

    // MARK: - dismiss 安全性

    func testDismissWithoutShowIsSafe() {
        let sut = BubbleWindow()
        sut.dismiss()
        XCTAssertFalse(sut.isShowing)
        XCTAssertNil(sut.dismissTimer)
    }

    func testMultipleDismissIsSafe() {
        let sut = BubbleWindow()
        for _ in 0..<5 {
            sut.dismiss()
        }
        XCTAssertFalse(sut.isShowing)
    }

    // MARK: - 独立インスタンス

    func testTwoInstancesAreIndependent() {
        let a = BubbleWindow()
        let b = BubbleWindow()
        a.dismiss()
        b.dismiss()
        XCTAssertFalse(a.isShowing)
        XCTAssertFalse(b.isShowing)
    }

    // MARK: - show ライフサイクル（DI seam 使用）

    func testShowSetsLastTextAndIsShowing() {
        let sut = makeHeadlessSUT()
        sut.show(text: "テスト", anchor: CGPoint(x: 100, y: 100))
        XCTAssertEqual(sut.lastText, "テスト")
        XCTAssertTrue(sut.isShowing)
    }

    func testShowThenDismissClearsIsShowing() {
        let sut = makeHeadlessSUT()
        sut.show(text: "テスト", anchor: CGPoint(x: 100, y: 100))
        sut.dismiss()
        XCTAssertFalse(sut.isShowing)
        XCTAssertNil(sut.dismissTimer)
    }

    func testShowWhileShowingReplacesText() {
        let sut = makeHeadlessSUT()
        sut.show(text: "最初", anchor: .zero)
        sut.show(text: "次", anchor: .zero)
        XCTAssertEqual(sut.lastText, "次")
        XCTAssertTrue(sut.isShowing)
    }

    // MARK: - auto-dismiss（手動タイマー使用）

    func testAutoDismissFiresViaTimer() {
        let (sut, fireTimer) = makeManualTimerSUT()
        sut.show(text: "自動消去", anchor: .zero)
        XCTAssertTrue(sut.isShowing)
        fireTimer()
        XCTAssertFalse(sut.isShowing)
    }

    func testDismissBeforeTimerIsIdempotent() {
        let (sut, fireTimer) = makeManualTimerSUT()
        sut.show(text: "手動消去", anchor: .zero)
        sut.dismiss()
        // タイマー発火しても安全
        fireTimer()
        XCTAssertFalse(sut.isShowing)
    }

    func testWindowFactoryReceivesCorrectText() {
        let sut = BubbleWindow()
        var receivedText: String?
        sut.windowFactory = { _, text in
            receivedText = text
            return nil
        }
        sut.show(text: "ファクトリテスト", anchor: .zero)
        XCTAssertEqual(receivedText, "ファクトリテスト")
    }

    func testWindowFactoryReceivesAnchor() {
        let sut = BubbleWindow()
        var receivedAnchor: CGPoint?
        sut.windowFactory = { anchor, _ in
            receivedAnchor = anchor
            return nil
        }
        sut.show(text: "座標テスト", anchor: CGPoint(x: 42, y: 99))
        XCTAssertEqual(receivedAnchor, CGPoint(x: 42, y: 99))
    }
}
