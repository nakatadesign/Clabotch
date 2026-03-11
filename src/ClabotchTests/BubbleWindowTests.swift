@testable import Clabotch
import XCTest

/// BubbleWindow のテスト。
/// ヘッドレステスト環境では NSWindow 生成 (show) が Signal 11 でクラッシュするため、
/// dismiss の安全性・冪等性と、初期状態の検証に集中する。
/// show + auto-dismiss はインテグレーションテスト（GUI 環境）で検証する。
final class BubbleWindowTests: XCTestCase {

    // MARK: - 初期状態

    func testInitialWindowIsNil() {
        let sut = BubbleWindow()
        XCTAssertNil(sut.window)
        XCTAssertFalse(sut.isShowing)
        XCTAssertNil(sut.lastText)
        XCTAssertNil(sut.dismissTimer)
    }

    // MARK: - dismiss 安全性

    func testDismissWithoutShowIsSafe() {
        let sut = BubbleWindow()
        sut.dismiss()
        XCTAssertNil(sut.window)
        XCTAssertNil(sut.dismissTimer)
    }

    func testMultipleDismissIsSafe() {
        let sut = BubbleWindow()
        sut.dismiss()
        sut.dismiss()
        sut.dismiss()
        XCTAssertNil(sut.window)
    }

    func testDismissAfterDismissIsSafe() {
        let sut = BubbleWindow()
        for _ in 0..<10 {
            sut.dismiss()
        }
        XCTAssertNil(sut.window)
    }

    // MARK: - 独立インスタンス（ephemeral bubble が active bubble を潰さない設計の検証）

    func testTwoInstancesAreIndependent() {
        let active = BubbleWindow()
        let ephemeral = BubbleWindow()
        // 別インスタンスなので互いに影響しない
        active.dismiss()
        XCTAssertNil(active.window)
        XCTAssertNil(ephemeral.window)
        ephemeral.dismiss()
        XCTAssertNil(ephemeral.window)
    }
}
