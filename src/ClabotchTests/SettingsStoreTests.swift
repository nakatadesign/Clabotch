@testable import Clabotch
import XCTest

/// SettingsStore の永続化と型安全アクセスのテスト。
/// テスト用 UserDefaults suite を使い、他のテストとの干渉を防ぐ。
final class SettingsStoreTests: XCTestCase {

    private var testDefaults: UserDefaults!
    private var store: SettingsStore!

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: "com.clabotch.tests.settings")!
        testDefaults.removePersistentDomain(forName: "com.clabotch.tests.settings")
        store = SettingsStore(defaults: testDefaults)
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: "com.clabotch.tests.settings")
        super.tearDown()
    }

    // MARK: - sleepTimeoutMinutes

    func testDefaultSleepTimeoutIs5Minutes() {
        XCTAssertEqual(store.sleepTimeoutMinutes, 5)
    }

    func testSetSleepTimeoutPersists() {
        store.sleepTimeoutMinutes = 10
        // 新しいインスタンスで読み直し
        let store2 = SettingsStore(defaults: testDefaults)
        XCTAssertEqual(store2.sleepTimeoutMinutes, 10)
    }

    func testSleepTimeoutZeroMeansDisabled() {
        store.sleepTimeoutMinutes = 0
        XCTAssertEqual(store.sleepTimeoutMinutes, 0)
        XCTAssertTrue(store.sleepTimeoutSeconds.isInfinite)
    }

    func testSleepTimeoutSecondsConversion() {
        store.sleepTimeoutMinutes = 1
        XCTAssertEqual(store.sleepTimeoutSeconds, 60)

        store.sleepTimeoutMinutes = 5
        XCTAssertEqual(store.sleepTimeoutSeconds, 300)

        store.sleepTimeoutMinutes = 10
        XCTAssertEqual(store.sleepTimeoutSeconds, 600)
    }

    func testDefaultSleepTimeoutSecondsIs300() {
        XCTAssertEqual(store.sleepTimeoutSeconds, 300)
    }

    // MARK: - onChange

    func testOnChangeFiresWhenSettingChanges() {
        var changeCount = 0
        store.onChange = { changeCount += 1 }

        store.sleepTimeoutMinutes = 10
        XCTAssertEqual(changeCount, 1)

        store.sleepTimeoutMinutes = 1
        XCTAssertEqual(changeCount, 2)
    }

    // MARK: - resetForTesting

    func testResetRestoresDefaults() {
        store.sleepTimeoutMinutes = 10
        store.resetForTesting()
        XCTAssertEqual(store.sleepTimeoutMinutes, 5) // デフォルトに戻る
    }

    // MARK: - sleepTimeoutOptions

    func testSleepTimeoutOptionsContainDefault() {
        let options = SettingsStore.sleepTimeoutOptions
        XCTAssertTrue(options.contains { $0.minutes == 5 })
        XCTAssertTrue(options.contains { $0.minutes == 0 }) // 無効
    }
}
