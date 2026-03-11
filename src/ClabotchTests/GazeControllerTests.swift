@testable import Clabotch
import XCTest

// MARK: - 6a. Override テスト

final class GazeControllerOverrideTests: XCTestCase {
    private var sut: GazeController!
    private var mockAX: MockAXProvider!
    private var mockWorkspace: MockWorkspaceProvider!

    override func setUp() {
        super.setUp()
        mockAX = MockAXProvider()
        mockWorkspace = MockWorkspaceProvider()
        sut = GazeController(
            axProvider: mockAX,
            workspaceProvider: mockWorkspace,
            pollInterval: 0.05
        )
    }

    override func tearDown() {
        sut.stopPolling()
        sut = nil
        UserDefaults.standard.removeObject(forKey: "didRequestAccessibility")
        super.tearDown()
    }

    func testSetOverrideFixedChangesMode() {
        sut.setOverride(.fixed(frame: .f01_center, reason: .mascotStateOverride))

        XCTAssertEqual(sut.mode, .fixed(.f01_center, reason: .mascotStateOverride))
        XCTAssertEqual(sut.gazeFrame, .f01_center)
    }

    func testSetOverrideNoneAllowsUpdate() {
        // override を設定してから .none に戻す
        sut.setOverride(.fixed(frame: .f01_center, reason: .mascotStateOverride))
        sut.setOverride(.none)

        // AX 権限なし → update() で permissionNotDetermined に再計算される
        sut.startPolling()

        let exp = expectation(description: "poll が発火して再計算される")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // override が none なので update() が走り、permission に基づく値になる
            XCTAssertEqual(self.sut.gazeFrame, .f02_rightDown)
            XCTAssertEqual(self.sut.mode, .fixed(.f02_rightDown, reason: .permissionNotDetermined))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testOverridePriorityOverPermission() {
        // 権限を denied にする
        UserDefaults.standard.set(true, forKey: "didRequestAccessibility")
        mockAX.isTrusted = false

        // override を設定
        sut.setOverride(.fixed(frame: .f01_center, reason: .mascotStateOverride))

        // polling 開始しても override が優先
        sut.startPolling()

        let exp = expectation(description: "override が優先される")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.sut.gazeFrame, .f01_center)
            XCTAssertEqual(self.sut.mode, .fixed(.f01_center, reason: .mascotStateOverride))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testOnGazeFrameChangedCallback() {
        var receivedFrames: [GazeFrame] = []
        sut.onGazeFrameChanged = { frame in
            receivedFrames.append(frame)
        }

        // 初期値は f02_rightDown。f01_center に変更 → コールバック発火
        sut.setOverride(.fixed(frame: .f01_center, reason: .mascotStateOverride))
        XCTAssertEqual(receivedFrames, [.f01_center])

        // 同じ frame で再設定 → コールバックは発火しない
        sut.setOverride(.fixed(frame: .f01_center, reason: .mascotStateOverride))
        XCTAssertEqual(receivedFrames, [.f01_center])

        // 別の frame に変更 → コールバック発火
        sut.setOverride(.fixed(frame: .f02_rightDown, reason: .mascotStateOverride))
        XCTAssertEqual(receivedFrames, [.f01_center, .f02_rightDown])
    }
}

// MARK: - 6b. Permission テスト

final class GazeControllerPermissionTests: XCTestCase {
    private var sut: GazeController!
    private var mockAX: MockAXProvider!
    private var mockWorkspace: MockWorkspaceProvider!

    override func setUp() {
        super.setUp()
        mockAX = MockAXProvider()
        mockWorkspace = MockWorkspaceProvider()
        sut = GazeController(
            axProvider: mockAX,
            workspaceProvider: mockWorkspace,
            pollInterval: 0.05
        )
        UserDefaults.standard.removeObject(forKey: "didRequestAccessibility")
    }

    override func tearDown() {
        sut.stopPolling()
        sut = nil
        UserDefaults.standard.removeObject(forKey: "didRequestAccessibility")
        super.tearDown()
    }

    func testPermissionNotDetermined() {
        mockAX.isTrusted = false
        // didRequestAccessibility = false (default)

        sut.startPolling()
        let exp = expectation(description: "poll 発火")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.sut.permissionStatus, .notDetermined)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testPermissionGranted() {
        mockAX.isTrusted = true

        sut.startPolling()
        let exp = expectation(description: "poll 発火")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.sut.permissionStatus, .granted)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testPermissionDenied() {
        mockAX.isTrusted = false
        UserDefaults.standard.set(true, forKey: "didRequestAccessibility")

        sut.startPolling()
        let exp = expectation(description: "poll 発火")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.sut.permissionStatus, .denied)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testPermissionDeniedFixedF02() {
        mockAX.isTrusted = false
        UserDefaults.standard.set(true, forKey: "didRequestAccessibility")

        sut.startPolling()
        let exp = expectation(description: "poll 発火")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.sut.mode, .fixed(.f02_rightDown, reason: .permissionDenied))
            XCTAssertEqual(self.sut.gazeFrame, .f02_rightDown)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testRequestPermissionCallsRequestTrust() {
        mockAX.isTrusted = false

        sut.requestPermissionIfNeeded { _ in }
        XCTAssertTrue(mockAX.requestTrustCalled)
    }

    func testRequestPermissionSetsDidRequestFlag() {
        mockAX.isTrusted = false

        sut.requestPermissionIfNeeded { _ in }
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "didRequestAccessibility"))
    }

    func testRequestPermissionCompletionCalled() {
        mockAX.isTrusted = false
        mockAX.requestTrustResult = false

        let exp = expectation(description: "completion が呼ばれる")
        sut.requestPermissionIfNeeded { status in
            // 1秒後のチェックで isTrusted=false, didRequest=true → denied
            XCTAssertEqual(status, .denied)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 3.0)
    }
}

// MARK: - 6c. Terminal 分類テスト

final class GazeControllerTerminalTests: XCTestCase {
    private var sut: GazeController!
    private var mockAX: MockAXProvider!
    private var mockWorkspace: MockWorkspaceProvider!

    override func setUp() {
        super.setUp()
        mockAX = MockAXProvider()
        mockAX.isTrusted = true
        mockWorkspace = MockWorkspaceProvider()
        sut = GazeController(
            axProvider: mockAX,
            workspaceProvider: mockWorkspace,
            pollInterval: 0.05
        )
        sut.statusItemCenterProvider = { CGPoint(x: 100, y: 10) }
        UserDefaults.standard.removeObject(forKey: "didRequestAccessibility")
    }

    override func tearDown() {
        sut.stopPolling()
        sut = nil
        UserDefaults.standard.removeObject(forKey: "didRequestAccessibility")
        super.tearDown()
    }

    func testSupportedTerminalTracking() {
        mockWorkspace.bundleIdentifier = "com.apple.Terminal"
        mockWorkspace.pid = 1234
        mockAX.terminalCenter = CGPoint(x: 500, y: 400)

        sut.startPolling()
        let exp = expectation(description: "tracking モード")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.sut.mode, .tracking)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testUnsupportedTerminalFixed() {
        mockWorkspace.bundleIdentifier = "dev.warp.desktop"
        mockWorkspace.pid = 1234

        sut.startPolling()
        let exp = expectation(description: "unsupportedTerminal")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.sut.mode, .fixed(.f02_rightDown, reason: .unsupportedTerminal))
            XCTAssertEqual(self.sut.gazeFrame, .f02_rightDown)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testNoFrontAppTerminalNotFound() {
        mockWorkspace.bundleIdentifier = nil

        sut.startPolling()
        let exp = expectation(description: "terminalNotFound")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.sut.mode, .fixed(.f01_center, reason: .terminalNotFound))
            XCTAssertEqual(self.sut.gazeFrame, .f01_center)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testNonTerminalAppNotFound() {
        mockWorkspace.bundleIdentifier = "com.apple.Safari"

        sut.startPolling()
        let exp = expectation(description: "terminalNotFound for non-terminal")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.sut.mode, .fixed(.f01_center, reason: .terminalNotFound))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testTerminalMinimized() {
        mockWorkspace.bundleIdentifier = "com.apple.Terminal"
        mockWorkspace.pid = 1234
        mockAX.terminalFailReason = .terminalMinimized

        sut.startPolling()
        let exp = expectation(description: "terminalMinimized")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.sut.mode, .fixed(.f01_center, reason: .terminalMinimized))
            XCTAssertEqual(self.sut.gazeFrame, .f01_center)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }
}

// MARK: - 6d. 量子化テスト

final class GazeControllerQuantizeTests: XCTestCase {
    private var sut: GazeController!
    private var mockAX: MockAXProvider!
    private var mockWorkspace: MockWorkspaceProvider!

    override func setUp() {
        super.setUp()
        mockAX = MockAXProvider()
        mockAX.isTrusted = true
        mockWorkspace = MockWorkspaceProvider()
        mockWorkspace.bundleIdentifier = "com.apple.Terminal"
        mockWorkspace.pid = 1234
        sut = GazeController(
            axProvider: mockAX,
            workspaceProvider: mockWorkspace,
            pollInterval: 0.05
        )
        // origin: (100, 10) — メニューバー上
        sut.statusItemCenterProvider = { CGPoint(x: 100, y: 10) }
        UserDefaults.standard.removeObject(forKey: "didRequestAccessibility")
    }

    override func tearDown() {
        sut.stopPolling()
        sut = nil
        UserDefaults.standard.removeObject(forKey: "didRequestAccessibility")
        super.tearDown()
    }

    func testQuantizeRightDown() {
        // target が origin の右下: dx > 0, dy < 0（macOS Y軸反転後）
        mockAX.terminalCenter = CGPoint(x: 500, y: 400)  // 右、下方向（macOS Y下が正）

        sut.startPolling()
        let exp = expectation(description: "rightDown")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.sut.gazeFrame, .f02_rightDown)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testQuantizeLeftDown() {
        // target が origin の左下: dx < 0, dy < 0（macOS Y軸反転後）
        mockAX.terminalCenter = CGPoint(x: 10, y: 400)

        sut.startPolling()
        let exp = expectation(description: "leftDown")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.sut.gazeFrame, .f03_leftDown)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testQuantizeLeftUp() {
        // target が origin の左上: dx < 0, dy > 0（macOS Y軸反転後）
        // macOS: 上 = Y値が小さい → target.y < origin.y → dy = -(target.y - origin.y) > 0
        mockAX.terminalCenter = CGPoint(x: 10, y: 5)

        sut.startPolling()
        let exp = expectation(description: "leftUp")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.sut.gazeFrame, .f04_leftUp)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testQuantizeRightUp() {
        // target が origin の右上: dx > 0, dy > 0（macOS Y軸反転後）
        mockAX.terminalCenter = CGPoint(x: 500, y: 5)

        sut.startPolling()
        let exp = expectation(description: "rightUp")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.sut.gazeFrame, .f05_rightUp)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }
}

// MARK: - 6e. Polling テスト

final class GazeControllerPollingTests: XCTestCase {
    private var sut: GazeController!
    private var mockAX: MockAXProvider!
    private var mockWorkspace: MockWorkspaceProvider!

    override func setUp() {
        super.setUp()
        mockAX = MockAXProvider()
        mockWorkspace = MockWorkspaceProvider()
        sut = GazeController(
            axProvider: mockAX,
            workspaceProvider: mockWorkspace,
            pollInterval: 0.05
        )
        UserDefaults.standard.removeObject(forKey: "didRequestAccessibility")
    }

    override func tearDown() {
        sut.stopPolling()
        sut = nil
        UserDefaults.standard.removeObject(forKey: "didRequestAccessibility")
        super.tearDown()
    }

    func testStartPollingCreatesTimer() {
        var updateCount = 0
        sut.onGazeFrameChanged = { _ in
            updateCount += 1
        }

        // 初期値 f02_rightDown → update() で permission check → f02_rightDown（同値なのでコールバックなし）
        // ただし permissionStatus が .notDetermined に変わるので mode は変わる
        sut.startPolling()

        let exp = expectation(description: "poll が少なくとも1回発火")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            // polling が動いていることの確認: permissionStatus が notDetermined になっている
            XCTAssertEqual(self.sut.permissionStatus, .notDetermined)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testStopPollingInvalidatesTimer() {
        mockAX.isTrusted = true
        mockWorkspace.bundleIdentifier = "com.apple.Terminal"
        mockWorkspace.pid = 1234
        mockAX.terminalCenter = CGPoint(x: 500, y: 400)
        sut.statusItemCenterProvider = { CGPoint(x: 100, y: 10) }

        sut.startPolling()

        let exp1 = expectation(description: "polling 開始後")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.sut.stopPolling()

            // 停止後に workspace を変更しても gazeFrame が更新されないことを確認
            self.mockWorkspace.bundleIdentifier = nil
            let frameAfterStop = self.sut.gazeFrame

            let exp2 = self.expectation(description: "停止後に変わらない")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                XCTAssertEqual(self.sut.gazeFrame, frameAfterStop)
                exp2.fulfill()
            }
            exp1.fulfill()
        }
        wait(for: [exp1], timeout: 1.0)
        waitForExpectations(timeout: 2.0)
    }

    func testStartPollingIdempotent() {
        sut.startPolling()
        sut.startPolling()  // 2回目は無視される

        let exp = expectation(description: "正常動作")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // 異常なくタイマーが1つだけ動いていることを確認
            XCTAssertEqual(self.sut.permissionStatus, .notDetermined)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }
}
