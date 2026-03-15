@testable import Clabotch
import XCTest

final class OnboardingWindowControllerTests: XCTestCase {

    /// テスト前後で alertPresenter を保存・復元
    private var originalPresenter: (() -> NSApplication.ModalResponse)!

    override func setUp() {
        super.setUp()
        originalPresenter = OnboardingWindowController.alertPresenter
        OnboardingWindowController.resetForTesting()
    }

    override func tearDown() {
        OnboardingWindowController.alertPresenter = originalPresenter
        OnboardingWindowController.resetForTesting()
        super.tearDown()
    }

    // MARK: - shouldShow

    func testShouldShowIsTrueOnFirstLaunch() {
        XCTAssertTrue(OnboardingWindowController.shouldShow)
    }

    func testShouldShowIsFalseAfterShown() {
        UserDefaults.standard.set(true, forKey: "didShowOnboarding")
        XCTAssertFalse(OnboardingWindowController.shouldShow)
    }

    func testResetForTestingClearsFlag() {
        UserDefaults.standard.set(true, forKey: "didShowOnboarding")
        OnboardingWindowController.resetForTesting()
        XCTAssertTrue(OnboardingWindowController.shouldShow)
    }

    // MARK: - show() ボタンマッピング

    func testShowAllowClickedMapsToAlertFirstButton() {
        // 「許可する」ボタン = alertFirstButtonReturn
        OnboardingWindowController.alertPresenter = { .alertFirstButtonReturn }

        var result: OnboardingWindowController.Result?
        OnboardingWindowController.show { result = $0 }

        XCTAssertEqual(result, .allowClicked)
        // ダイアログ完了後にフラグが立つ
        XCTAssertFalse(OnboardingWindowController.shouldShow)
    }

    func testShowLaterClickedMapsToAlertSecondButton() {
        // 「後で」ボタン = alertSecondButtonReturn
        OnboardingWindowController.alertPresenter = { .alertSecondButtonReturn }

        var result: OnboardingWindowController.Result?
        OnboardingWindowController.show { result = $0 }

        XCTAssertEqual(result, .laterClicked)
        XCTAssertFalse(OnboardingWindowController.shouldShow)
    }

    func testFlagNotSetBeforeDialogCompletes() {
        // alertPresenter 実行中は shouldShow がまだ true であること
        var shouldShowDuringPresenter: Bool?
        OnboardingWindowController.alertPresenter = {
            shouldShowDuringPresenter = OnboardingWindowController.shouldShow
            return .alertFirstButtonReturn
        }

        OnboardingWindowController.show { _ in }

        XCTAssertTrue(shouldShowDuringPresenter ?? false,
                      "ダイアログ表示中はまだ shouldShow=true であるべき（クラッシュ時に再表示可能）")
        XCTAssertFalse(OnboardingWindowController.shouldShow,
                       "ダイアログ完了後は shouldShow=false であるべき")
    }
}

// MARK: - AX 権限復旧アラートのテスト

final class AccessibilityAlertTests: XCTestCase {

    private var originalPresenter: (() -> NSApplication.ModalResponse)!

    override func setUp() {
        super.setUp()
        originalPresenter = AppDelegate.accessibilityAlertPresenter
    }

    override func tearDown() {
        AppDelegate.accessibilityAlertPresenter = originalPresenter
        super.tearDown()
    }

    func testAccessibilityAlertPresenterIsReplaceable() {
        // テスト seam が機能することを確認
        var called = false
        AppDelegate.accessibilityAlertPresenter = {
            called = true
            return .alertSecondButtonReturn
        }

        let result = AppDelegate.accessibilityAlertPresenter()
        XCTAssertTrue(called)
        XCTAssertEqual(result, .alertSecondButtonReturn)
    }

    func testAccessibilityAlertFirstButtonReturnsCorrectResponse() {
        AppDelegate.accessibilityAlertPresenter = { .alertFirstButtonReturn }
        let result = AppDelegate.accessibilityAlertPresenter()
        XCTAssertEqual(result, .alertFirstButtonReturn, "「システム設定を開く」は alertFirstButtonReturn")
    }

    func testAccessibilityAlertSecondButtonReturnsCorrectResponse() {
        AppDelegate.accessibilityAlertPresenter = { .alertSecondButtonReturn }
        let result = AppDelegate.accessibilityAlertPresenter()
        XCTAssertEqual(result, .alertSecondButtonReturn, "「後で」は alertSecondButtonReturn")
    }
}
