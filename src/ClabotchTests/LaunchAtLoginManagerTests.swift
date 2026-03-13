@testable import Clabotch
import XCTest

/// LaunchAtLoginProviding のモック実装。
final class MockLaunchAtLoginProvider: LaunchAtLoginProviding {
    var isEnabled: Bool = false
    var setEnabledError: Error?
    private(set) var setEnabledCalls: [Bool] = []

    func setEnabled(_ enabled: Bool) throws {
        setEnabledCalls.append(enabled)
        if let error = setEnabledError {
            throw error
        }
        isEnabled = enabled
    }
}

/// LaunchAtLoginProviding プロトコルとモックのテスト。
/// SMAppService は CI/テスト環境で動作しないため、モックベースで検証する。
final class LaunchAtLoginManagerTests: XCTestCase {

    // MARK: - MockLaunchAtLoginProvider

    func testMockInitialStateIsDisabled() {
        let mock = MockLaunchAtLoginProvider()
        XCTAssertFalse(mock.isEnabled)
    }

    func testMockSetEnabledTrue() throws {
        let mock = MockLaunchAtLoginProvider()
        try mock.setEnabled(true)
        XCTAssertTrue(mock.isEnabled)
        XCTAssertEqual(mock.setEnabledCalls, [true])
    }

    func testMockSetEnabledFalse() throws {
        let mock = MockLaunchAtLoginProvider()
        mock.isEnabled = true
        try mock.setEnabled(false)
        XCTAssertFalse(mock.isEnabled)
    }

    func testMockSetEnabledThrowsError() {
        let mock = MockLaunchAtLoginProvider()
        mock.setEnabledError = NSError(domain: "test", code: 1)
        XCTAssertThrowsError(try mock.setEnabled(true))
        XCTAssertFalse(mock.isEnabled) // エラー時は状態変更しない
    }

    func testMockRecordsMultipleCalls() throws {
        let mock = MockLaunchAtLoginProvider()
        try mock.setEnabled(true)
        try mock.setEnabled(false)
        try mock.setEnabled(true)
        XCTAssertEqual(mock.setEnabledCalls, [true, false, true])
    }
}

/// SettingsWindowController の LaunchAtLogin チェックボックス連携テスト。
@MainActor
final class SettingsWindowLaunchAtLoginTests: XCTestCase {

    private var testDefaults: UserDefaults!
    private var store: SettingsStore!
    private var mockLaunch: MockLaunchAtLoginProvider!

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: "com.clabotch.tests.launchWC")!
        testDefaults.removePersistentDomain(forName: "com.clabotch.tests.launchWC")
        store = SettingsStore(defaults: testDefaults)
        mockLaunch = MockLaunchAtLoginProvider()
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: "com.clabotch.tests.launchWC")
        super.tearDown()
    }

    private func makeHeadlessSUT() -> SettingsWindowController {
        let wc = SettingsWindowController(settingsStore: store, launchAtLogin: mockLaunch)
        wc.windowFactory = { _ in nil }
        return wc
    }

    func testCheckboxReflectsInitialDisabledState() {
        mockLaunch.isEnabled = false
        let wc = makeHeadlessSUT()
        wc.showWindow()
        XCTAssertEqual(wc.launchAtLoginCheckbox?.state, .off)
    }

    func testCheckboxReflectsInitialEnabledState() {
        mockLaunch.isEnabled = true
        let wc = makeHeadlessSUT()
        wc.showWindow()
        XCTAssertEqual(wc.launchAtLoginCheckbox?.state, .on)
    }

    /// ヘッドレス環境で checkbox のアクションを発火するヘルパー。
    /// ウィンドウ階層にない NSButton は performClick / NSApp.sendAction でアクションが
    /// 発火しないため、state を手動トグルしてから perform selector で直接呼ぶ。
    private func simulateCheckboxClick(_ checkbox: NSButton) {
        checkbox.state = checkbox.state == .on ? .off : .on
        (checkbox.target as AnyObject).perform(checkbox.action, with: checkbox)
    }

    func testCheckboxTogglesCallsSetEnabled() throws {
        let wc = makeHeadlessSUT()
        wc.showWindow()

        let checkbox = try XCTUnwrap(wc.launchAtLoginCheckbox)
        simulateCheckboxClick(checkbox)

        XCTAssertEqual(mockLaunch.setEnabledCalls, [true])
        XCTAssertTrue(mockLaunch.isEnabled)
    }

    func testCheckboxRevertsOnError() throws {
        mockLaunch.setEnabledError = NSError(domain: "test", code: 1)
        let wc = makeHeadlessSUT()
        wc.showWindow()

        let checkbox = try XCTUnwrap(wc.launchAtLoginCheckbox)
        simulateCheckboxClick(checkbox)

        // mockLaunch.isEnabled は false のまま → checkbox も off に戻る
        XCTAssertEqual(checkbox.state, .off)
    }
}
