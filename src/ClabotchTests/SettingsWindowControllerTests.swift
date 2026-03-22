@testable import Clabotch
import XCTest

/// SettingsWindowController のテスト。
/// windowFactory に nil を返すスタブを注入してヘッドレスで動作検証する。
@MainActor
final class SettingsWindowControllerTests: XCTestCase {

    private var testDefaults: UserDefaults!
    private var store: SettingsStore!

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: "com.clabotch.tests.settingsWC")!
        testDefaults.removePersistentDomain(forName: "com.clabotch.tests.settingsWC")
        store = SettingsStore(defaults: testDefaults)
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: "com.clabotch.tests.settingsWC")
        super.tearDown()
    }

    private func makeHeadlessSUT() -> SettingsWindowController {
        let wc = SettingsWindowController(settingsStore: store)
        wc.windowFactory = { _ in nil }
        return wc
    }

    // MARK: - 基本ライフサイクル

    func testInitialStateNotVisible() {
        let wc = makeHeadlessSUT()
        XCTAssertFalse(wc.isVisible)
    }

    func testShowWindowHeadless() {
        let wc = makeHeadlessSUT()
        wc.showWindow()
        // ヘッドレス（windowFactory=nil）なので isVisible は false のまま
        XCTAssertFalse(wc.isVisible)
    }

    func testCloseWithoutShowIsSafe() {
        let wc = makeHeadlessSUT()
        wc.close()
        XCTAssertFalse(wc.isVisible)
    }

    // MARK: - AX 権限 UI

    func testRefreshAccessibilityStatusUpdatesLabel() {
        let wc = makeHeadlessSUT()
        wc.showWindow()
        // ヘッドレスでも axStatusLabel は buildContentView 経由で生成される
        // ただし windowFactory=nil だと buildContentView が呼ばれない
        // → refreshAccessibilityStatus が nil-safe であることを確認
        wc.refreshAccessibilityStatus()  // クラッシュしないこと
    }

    func testAxSettingsButtonExistsAfterShow() {
        // windowFactory を実際のウィンドウを返すように設定
        let wc = SettingsWindowController(settingsStore: store)
        wc.windowFactory = { _ in nil }
        wc.showWindow()
        // axSettingsButton が構築されていること
        XCTAssertNotNil(wc.axSettingsButton)
        XCTAssertNotNil(wc.axStatusLabel)
    }

    func testAnimSpeedPopupExistsAfterShow() {
        let wc = SettingsWindowController(settingsStore: store)
        wc.windowFactory = { _ in nil }
        wc.showWindow()
        XCTAssertNotNil(wc.animSpeedPopup)
        XCTAssertEqual(wc.animSpeedPopup?.numberOfItems, 3)
    }

    func testAnimSpeedPopupReflectsCurrentSetting() {
        store.animationSpeedPreset = 2  // fast
        let wc = SettingsWindowController(settingsStore: store)
        wc.windowFactory = { _ in nil }
        wc.showWindow()
        XCTAssertEqual(wc.animSpeedPopup?.selectedItem?.title, L10n.animationSpeedFast)
    }
}

// MARK: - StateMachine.updateSleepThreshold テスト

@MainActor
final class StateMachineUpdateSleepThresholdTests: XCTestCase {

    func testUpdateSleepThresholdChangesValue() {
        let sm = StateMachine(sleepThreshold: 300)
        XCTAssertEqual(sm.sleepThreshold, 300)

        sm.updateSleepThreshold(600)
        XCTAssertEqual(sm.sleepThreshold, 600)
    }

    func testUpdateSleepThresholdInfinityDisablesSleep() {
        let sm = StateMachine(sleepThreshold: 0.1)
        sm.start()

        // スリープ無効に変更
        sm.updateSleepThreshold(.infinity)

        // スリープ発火しないことを検証
        let exp = expectation(description: "no sleep with infinity")
        exp.isInverted = true
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            if sm.displayPhase == .sleeping {
                timer.invalidate()
                exp.fulfill()
            }
        }
        waitForExpectations(timeout: 0.3) { _ in timer.invalidate() }
    }

    func testUpdateSleepThresholdRestartsTimer() {
        let sm = StateMachine(sleepThreshold: 10)
        sm.start()
        XCTAssertEqual(sm.displayPhase, .idle)

        // 短いタイムアウトに変更 → sleep 発火を待つ
        sm.updateSleepThreshold(0.1)

        let exp = expectation(description: "sleep after threshold update")
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            if sm.displayPhase == .sleeping {
                timer.invalidate()
                exp.fulfill()
            }
        }
        waitForExpectations(timeout: 1) { _ in timer.invalidate() }
    }

    /// スリープ中に閾値を変更すると idle に戻る
    func testUpdateSleepThresholdWhileSleepingWakesUp() {
        let sm = StateMachine(sleepThreshold: 0.05)
        sm.start()

        // スリープに入るのを待つ
        let sleepExp = expectation(description: "enter sleep")
        let pollTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { timer in
            if sm.displayPhase == .sleeping {
                timer.invalidate()
                sleepExp.fulfill()
            }
        }
        waitForExpectations(timeout: 1) { _ in pollTimer.invalidate() }
        XCTAssertEqual(sm.displayPhase, .sleeping)

        // スリープ無効に変更 → idle に戻る
        sm.updateSleepThreshold(.infinity)
        XCTAssertEqual(sm.displayPhase, .idle)
    }

    /// スリープ中に有限の閾値に変更すると idle に戻り、新タイマーが始動する
    func testUpdateSleepThresholdWhileSleepingRestartsWithNewThreshold() {
        let sm = StateMachine(sleepThreshold: 0.05)
        sm.start()

        // スリープに入るのを待つ
        let sleepExp = expectation(description: "enter sleep")
        let pollTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { timer in
            if sm.displayPhase == .sleeping {
                timer.invalidate()
                sleepExp.fulfill()
            }
        }
        waitForExpectations(timeout: 1) { _ in pollTimer.invalidate() }
        XCTAssertEqual(sm.displayPhase, .sleeping)

        // 新しい閾値に変更 → idle に戻り、再度スリープに入る
        sm.updateSleepThreshold(0.05)
        XCTAssertEqual(sm.displayPhase, .idle)

        let reSleepExp = expectation(description: "re-enter sleep")
        let reTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { timer in
            if sm.displayPhase == .sleeping {
                timer.invalidate()
                reSleepExp.fulfill()
            }
        }
        waitForExpectations(timeout: 1) { _ in reTimer.invalidate() }
    }
}

// MARK: - StateMachine.wakeFromSleep テスト

@MainActor
final class StateMachineWakeFromSleepTests: XCTestCase {

    func testWakeFromSleepTransitionsToIdle() {
        let sm = StateMachine(sleepThreshold: 0.05)
        sm.start()

        // sleeping に入るのを待つ
        let sleepExp = expectation(description: "enter sleep")
        let timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { timer in
            if sm.displayPhase == .sleeping {
                timer.invalidate()
                sleepExp.fulfill()
            }
        }
        waitForExpectations(timeout: 1) { _ in timer.invalidate() }
        XCTAssertEqual(sm.displayPhase, .sleeping)

        // wakeFromSleep → idle に復帰
        sm.wakeFromSleep()
        XCTAssertEqual(sm.displayPhase, .idle)
    }

    func testWakeFromSleepNoOpWhenNotSleeping() {
        let sm = StateMachine(sleepThreshold: 300)
        sm.start()
        XCTAssertEqual(sm.displayPhase, .idle)

        // idle 中に wakeFromSleep → 何も起きない
        sm.wakeFromSleep()
        XCTAssertEqual(sm.displayPhase, .idle)
    }

    func testWakeFromSleepRestartsTimer() {
        let sm = StateMachine(sleepThreshold: 0.05)
        sm.start()

        // sleeping に入るのを待つ
        let sleepExp = expectation(description: "enter sleep")
        let timer1 = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { timer in
            if sm.displayPhase == .sleeping {
                timer.invalidate()
                sleepExp.fulfill()
            }
        }
        waitForExpectations(timeout: 1) { _ in timer1.invalidate() }

        // wakeFromSleep → idle → 再び sleeping に入る
        sm.wakeFromSleep()
        XCTAssertEqual(sm.displayPhase, .idle)

        let reSleepExp = expectation(description: "re-enter sleep after wake")
        let timer2 = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { timer in
            if sm.displayPhase == .sleeping {
                timer.invalidate()
                reSleepExp.fulfill()
            }
        }
        waitForExpectations(timeout: 1) { _ in timer2.invalidate() }
    }
}
