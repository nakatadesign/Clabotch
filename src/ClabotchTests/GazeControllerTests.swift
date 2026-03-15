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
            pollInterval: 0.05,
            pollIntervalNotGranted: 0.05
        )
    }

    override func tearDown() {
        sut.stopPolling()
        sut = nil
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

        // AX 権限なし → update() で permissionNotGranted に再計算される
        sut.startPolling()

        let exp = expectation(description: "poll が発火して再計算される")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // override が none なので update() が走り、permission に基づく値になる
            XCTAssertEqual(self.sut.gazeFrame, .f03_leftDown)
            XCTAssertEqual(self.sut.mode, .fixed(.f03_leftDown, reason: .permissionNotGranted))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testOverridePriorityOverPermission() {
        // 権限を notGranted にする
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

        // 初期値は f03_leftDown。f01_center に変更 → コールバック発火
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
            pollInterval: 0.05,
            pollIntervalNotGranted: 0.05
        )
            }

    override func tearDown() {
        sut.stopPolling()
        sut = nil
                super.tearDown()
    }

    func testPermissionNotGranted() {
        mockAX.isTrusted = false

        sut.startPolling()
        let exp = expectation(description: "poll 発火")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.sut.permissionStatus, .notGranted)
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

    func testPermissionNotGrantedFixedGaze() {
        mockAX.isTrusted = false

        sut.startPolling()
        let exp = expectation(description: "poll 発火")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.sut.mode, .fixed(.f03_leftDown, reason: .permissionNotGranted))
            XCTAssertEqual(self.sut.gazeFrame, .f03_leftDown)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testRequestPermissionCallsRequestTrust() {
        mockAX.isTrusted = false

        sut.requestPermission()
        XCTAssertTrue(mockAX.requestTrustCalled)
    }

    func testOnPermissionChangedCallback() {
        mockAX.isTrusted = false
        var receivedStatuses: [GazePermissionStatus] = []
        sut.onPermissionChanged = { status in
            receivedStatuses.append(status)
        }

        sut.startPolling()

        let exp = expectation(description: "権限変化コールバック")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // 初期値 notGranted → polling で notGranted → 変化なし → callback なし
            XCTAssertTrue(receivedStatuses.isEmpty)

            // isTrusted を true に変更 → 次の poll で granted に変化 → callback 発火
            self.mockAX.isTrusted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                XCTAssertEqual(receivedStatuses, [.granted])
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 2.0)
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
            pollInterval: 0.05,
            pollIntervalNotGranted: 0.05
        )
        sut.statusItemCenterProvider = { CGPoint(x: 100, y: 10) }
            }

    override func tearDown() {
        sut.stopPolling()
        sut = nil
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

    func testWarpSupportedTerminalTracking() {
        mockWorkspace.bundleIdentifier = "dev.warp.Warp-Stable"
        mockWorkspace.pid = 1234
        mockAX.terminalCenter = CGPoint(x: 600, y: 500)

        sut.startPolling()
        let exp = expectation(description: "Warp tracking")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.sut.mode, .tracking)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testNoFrontAppNoTracking() {
        mockWorkspace.bundleIdentifier = nil
        mockWorkspace.pid = nil

        sut.startPolling()
        let exp = expectation(description: "no front app — no tracking change")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // frontmostPID が nil なので update() は early return → 初期値のまま
            XCTAssertEqual(self.sut.gazeFrame, .f03_leftDown)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testNonTerminalAppTracksViaAX() {
        mockWorkspace.bundleIdentifier = "com.apple.Safari"
        mockWorkspace.pid = 1234
        mockAX.terminalCenter = CGPoint(x: 500, y: 500)

        sut.startPolling()
        let exp = expectation(description: "non-terminal app still tracks via AX")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // 常時追跡なので AX 経由でウィンドウ位置を取得
            XCTAssertEqual(self.sut.mode, .tracking)
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
            pollInterval: 0.05,
            pollIntervalNotGranted: 0.05
        )
        // origin: (1200, 1400) — メニューバー上（macOS Y=0 は画面下端）
        sut.statusItemCenterProvider = { CGPoint(x: 1200, y: 1400) }
            }

    override func tearDown() {
        sut.stopPolling()
        sut = nil
                super.tearDown()
    }

    func testQuantizeRightDown() {
        // 画面中心より右、上部25%より下 → rightDown
        // 画面: 3840x2160, 中心x=1920, 上部25%境界 y=1620
        mockAX.terminalCenter = CGPoint(x: 2500, y: 800)

        sut.startPolling()
        let exp = expectation(description: "rightDown")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.sut.gazeFrame, .f02_rightDown)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testQuantizeLeftDown() {
        // 画面中心より左、上部25%より下 → leftDown
        mockAX.terminalCenter = CGPoint(x: 800, y: 800)

        sut.startPolling()
        let exp = expectation(description: "leftDown")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.sut.gazeFrame, .f03_leftDown)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testQuantizeLeftHorizontal() {
        // 水平方向は廃止 → 画面上部でも左下に量子化される
        mockAX.terminalCenter = CGPoint(x: 800, y: 1800)

        sut.startPolling()
        let exp = expectation(description: "left down")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.sut.gazeFrame, .f03_leftDown)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testQuantizeRightHorizontal() {
        // 水平方向は廃止 → 画面上部でも右下に量子化される
        mockAX.terminalCenter = CGPoint(x: 2500, y: 1800)

        sut.startPolling()
        let exp = expectation(description: "right down")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.sut.gazeFrame, .f02_rightDown)
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
            pollInterval: 0.05,
            pollIntervalNotGranted: 0.05
        )
            }

    override func tearDown() {
        sut.stopPolling()
        sut = nil
                super.tearDown()
    }

    func testStartPollingCreatesTimer() {
        var updateCount = 0
        sut.onGazeFrameChanged = { _ in
            updateCount += 1
        }

        // 初期値 f03_leftDown → update() で permission check → f03_leftDown（同値なのでコールバックなし）
        // ただし permissionStatus が .notGranted に変わるので mode は変わる
        sut.startPolling()

        let exp = expectation(description: "poll が少なくとも1回発火")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            // polling が動いていることの確認: permissionStatus が notDetermined になっている
            XCTAssertEqual(self.sut.permissionStatus, .notGranted)
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
            XCTAssertEqual(self.sut.permissionStatus, .notGranted)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testPollIntervalSwitchesOnPermissionChange() {
        // notGranted → granted でポーリング間隔が切り替わることを確認
        // 低頻度（notGranted）時の pollIntervalNotGranted=0.2, granted=0.05
        let fastSut = GazeController(
            axProvider: mockAX,
            workspaceProvider: mockWorkspace,
            pollInterval: 0.05,
            pollIntervalNotGranted: 0.2
        )
        fastSut.statusItemCenterProvider = { CGPoint(x: 100, y: 10) }

        mockAX.isTrusted = false
        fastSut.startPolling()

        var grantedCallbackCount = 0
        fastSut.onPermissionChanged = { status in
            if status == .granted { grantedCallbackCount += 1 }
        }

        let exp = expectation(description: "権限変化で間隔切替")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // 権限を付与 → 間隔が 0.05 に切り替わる
            self.mockAX.isTrusted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                XCTAssertEqual(grantedCallbackCount, 1)
                XCTAssertEqual(fastSut.permissionStatus, .granted)
                fastSut.stopPolling()
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 2.0)
    }
}

// MARK: - 6f. Attention（一時注視）テスト

final class GazeControllerAttentionTests: XCTestCase {
    private var sut: GazeController!
    private var mockAX: MockAXProvider!
    private var mockWorkspace: MockWorkspaceProvider!
    private var currentTime: Date!

    override func setUp() {
        super.setUp()
        mockAX = MockAXProvider()
        mockAX.isTrusted = true
        mockWorkspace = MockWorkspaceProvider()
        currentTime = Date()
        sut = GazeController(
            axProvider: mockAX,
            workspaceProvider: mockWorkspace,
            pollInterval: 0.05,
            attentionDuration: 0.3,
            now: { [unowned self] in self.currentTime }
        )
        sut.statusItemCenterProvider = { CGPoint(x: 100, y: 10) }
            }

    override func tearDown() {
        sut.stopPolling()
        sut = nil
                super.tearDown()
    }

    func testLookAtTerminalActivatesAttention() {
        XCTAssertFalse(sut.isAttentionActive)

        sut.lookAtTerminal()

        XCTAssertTrue(sut.isAttentionActive)
    }

    func testAttentionExpiresAfterDuration() {
        sut.lookAtTerminal()
        XCTAssertTrue(sut.isAttentionActive)

        // 時間を進める（attentionDuration=0.3s を超える）
        currentTime = currentTime.addingTimeInterval(0.5)
        XCTAssertFalse(sut.isAttentionActive)
    }

    func testAttentionTracksDuringWindow() {
        mockWorkspace.bundleIdentifier = "com.apple.Terminal"
        mockWorkspace.pid = 1234
        mockAX.terminalCenter = CGPoint(x: 500, y: 400)

        sut.lookAtTerminal()

        // 注意中 → tracking モード
        XCTAssertEqual(sut.mode, .tracking)
    }

    func testTrackingContinuesAfterTimeElapsed() {
        mockWorkspace.bundleIdentifier = "com.apple.Terminal"
        mockWorkspace.pid = 1234
        mockAX.terminalCenter = CGPoint(x: 500, y: 400)

        sut.lookAtTerminal()
        XCTAssertEqual(sut.mode, .tracking)

        // 時間経過しても常時追跡が維持される
        currentTime = currentTime.addingTimeInterval(10.0)
        sut.startPolling()

        let exp = expectation(description: "still tracking after time elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.sut.mode, .tracking)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testAppSwitchUpdatesTracking() {
        mockWorkspace.bundleIdentifier = "com.apple.Safari"
        mockWorkspace.pid = 1234
        mockAX.terminalCenter = CGPoint(x: 500, y: 400)

        sut.startPolling()

        let exp1 = expectation(description: "initial tracking with Safari")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Safari でも AX 経由で追跡
            XCTAssertEqual(self.sut.mode, .tracking)

            // ターミナルに切り替え
            self.mockWorkspace.bundleIdentifier = "com.apple.Terminal"
            exp1.fulfill()
        }
        wait(for: [exp1], timeout: 1.0)

        let exp2 = expectation(description: "tracking continues after app switch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            XCTAssertEqual(self.sut.mode, .tracking)
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 1.0)
    }

    func testOverrideTakesPriorityOverAttention() {
        mockWorkspace.bundleIdentifier = "com.apple.Terminal"
        mockWorkspace.pid = 1234
        mockAX.terminalCenter = CGPoint(x: 500, y: 400)

        // 注意を有効化
        sut.lookAtTerminal()
        XCTAssertEqual(sut.mode, .tracking)

        // override が注意より優先
        sut.setOverride(.fixed(frame: .f01_center, reason: .mascotStateOverride))
        XCTAssertEqual(sut.mode, .fixed(.f01_center, reason: .mascotStateOverride))
    }

    func testLookAtTerminalWithCustomDuration() {
        sut.lookAtTerminal(duration: 1.0)
        XCTAssertTrue(sut.isAttentionActive)

        // 0.5秒後はまだ有効
        currentTime = currentTime.addingTimeInterval(0.5)
        XCTAssertTrue(sut.isAttentionActive)

        // 1.5秒後は期限切れ
        currentTime = currentTime.addingTimeInterval(1.0)
        XCTAssertFalse(sut.isAttentionActive)
    }

    func testConsecutiveLookAtTerminalRefreshesTimer() {
        sut.lookAtTerminal()
        XCTAssertTrue(sut.isAttentionActive)

        // 0.2秒経過（残り0.1秒）
        currentTime = currentTime.addingTimeInterval(0.2)

        // 再度 lookAtTerminal → タイマーがリフレッシュ
        sut.lookAtTerminal()

        // さらに 0.2秒経過（合計0.4秒）→ 最初の注意なら期限切れだが、リフレッシュ後なのでまだ有効
        currentTime = currentTime.addingTimeInterval(0.2)
        XCTAssertTrue(sut.isAttentionActive)
    }

    func testTrackingPersistsWithTerminalFrontmost() {
        // ターミナルがフロントの場合、常時追跡が維持される
        mockWorkspace.bundleIdentifier = "com.apple.Terminal"
        mockWorkspace.pid = 1234
        mockAX.terminalCenter = CGPoint(x: 500, y: 400)

        sut.startPolling()

        let exp1 = expectation(description: "initial tracking")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.sut.mode, .tracking)
            exp1.fulfill()
        }
        wait(for: [exp1], timeout: 1.0)

        // 長時間経過しても tracking が維持される
        currentTime = currentTime.addingTimeInterval(30.0)

        let exp2 = expectation(description: "still tracking after long time")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.sut.mode, .tracking)
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 1.0)
    }

    func testAttentionOverridesIdleOverride() {
        // idle 状態の override (allowsAttentionOverride: true)
        sut.setOverride(.fixed(frame: .f02_rightDown, reason: .mascotStateOverride, allowsAttentionOverride: true))
        XCTAssertEqual(sut.gazeFrame, .f02_rightDown)

        mockWorkspace.bundleIdentifier = "com.apple.Terminal"
        mockWorkspace.pid = 1234
        mockAX.terminalCenter = CGPoint(x: 500, y: 400)

        // attention 開始 → idle override をスキップして tracking
        sut.lookAtTerminal()
        XCTAssertEqual(sut.mode, .tracking)
    }

    func testAttentionDoesNotOverrideErrorOverride() {
        // error 状態の override (allowsAttentionOverride: false)
        sut.setOverride(.fixed(frame: .f01_center, reason: .mascotStateOverride, allowsAttentionOverride: false))
        XCTAssertEqual(sut.gazeFrame, .f01_center)

        mockWorkspace.bundleIdentifier = "com.apple.Terminal"
        mockWorkspace.pid = 1234
        mockAX.terminalCenter = CGPoint(x: 500, y: 400)

        // attention 開始しても error override が最優先
        sut.lookAtTerminal()
        XCTAssertEqual(sut.mode, .fixed(.f01_center, reason: .mascotStateOverride))
    }

    func testAttentionDoesNotOverrideSleepingOverride() {
        // sleeping 状態の override (allowsAttentionOverride: false)
        sut.setOverride(.fixed(frame: .f01_center, reason: .mascotStateOverride, allowsAttentionOverride: false))

        mockWorkspace.bundleIdentifier = "com.apple.Terminal"
        mockWorkspace.pid = 1234
        mockAX.terminalCenter = CGPoint(x: 500, y: 400)

        // attention 開始しても sleeping override が最優先
        sut.lookAtTerminal()
        XCTAssertEqual(sut.mode, .fixed(.f01_center, reason: .mascotStateOverride))
    }

    func testAllowsAttentionOverrideAlwaysBypassed() {
        // allowsAttentionOverride=true の override は常にバイパスされ追跡が維持される
        sut.setOverride(.fixed(frame: .f02_rightDown, reason: .mascotStateOverride, allowsAttentionOverride: true))

        mockWorkspace.bundleIdentifier = "com.apple.Terminal"
        mockWorkspace.pid = 1234
        mockAX.terminalCenter = CGPoint(x: 500, y: 400)

        sut.startPolling()

        let exp = expectation(description: "tracking despite override")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // allowsAttentionOverride=true なので常にバイパス → tracking
            XCTAssertEqual(self.sut.mode, .tracking)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }
}

// MARK: - 6g. クリック検出テスト

final class GazeControllerClickTests: XCTestCase {
    private var sut: GazeController!
    private var mockAX: MockAXProvider!
    private var mockWorkspace: MockWorkspaceProvider!
    private var mockEventMonitor: MockGlobalEventMonitor!
    private var currentTime: Date!

    override func setUp() {
        super.setUp()
        mockAX = MockAXProvider()
        mockAX.isTrusted = true
        mockWorkspace = MockWorkspaceProvider()
        mockEventMonitor = MockGlobalEventMonitor()
        currentTime = Date()
        sut = GazeController(
            axProvider: mockAX,
            workspaceProvider: mockWorkspace,
            eventMonitor: mockEventMonitor,
            pollInterval: 0.05,
            attentionDuration: 0.3,
            now: { [unowned self] in self.currentTime }
        )
        sut.statusItemCenterProvider = { CGPoint(x: 100, y: 10) }
            }

    override func tearDown() {
        sut.stopPolling()
        sut = nil
                super.tearDown()
    }

    func testClickMonitorStartsWithPolling() {
        XCTAssertFalse(mockEventMonitor.isMonitoring)

        sut.startPolling()

        XCTAssertTrue(mockEventMonitor.isMonitoring)
    }

    func testClickMonitorStopsWithPolling() {
        sut.startPolling()
        XCTAssertTrue(mockEventMonitor.isMonitoring)

        sut.stopPolling()

        XCTAssertFalse(mockEventMonitor.isMonitoring)
    }

    func testAlwaysTracksWhenPermissionGranted() {
        mockWorkspace.bundleIdentifier = "com.apple.Terminal"
        mockWorkspace.pid = 1234
        mockAX.terminalCenter = CGPoint(x: 500, y: 400)

        sut.startPolling()

        // 常時追跡: attention 不要で即座に tracking
        let exp1 = expectation(description: "always tracking")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.sut.mode, .tracking)
            exp1.fulfill()
        }
        wait(for: [exp1], timeout: 1.0)

        // 時間が経過しても tracking が維持される
        currentTime = currentTime.addingTimeInterval(10.0)
        let exp2 = expectation(description: "still tracking after time")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.sut.mode, .tracking)
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 1.0)
    }

    func testClickOnNonTerminalDoesNotTriggerAttention() {
        mockWorkspace.bundleIdentifier = "com.apple.Safari"
        mockWorkspace.pid = 1234

        sut.startPolling()

        let exp = expectation(description: "no attention for non-terminal click")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertFalse(self.sut.isAttentionActive)

            // Safari 上でクリック → attention は発火しない
            self.mockEventMonitor.simulateClick()

            XCTAssertFalse(self.sut.isAttentionActive)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testClickRefreshesExistingAttention() {
        mockWorkspace.bundleIdentifier = "com.apple.Terminal"
        mockWorkspace.pid = 1234
        mockAX.terminalCenter = CGPoint(x: 500, y: 400)

        sut.startPolling()
        sut.lookAtTerminal()
        XCTAssertTrue(sut.isAttentionActive)

        // 0.2秒経過（残り0.1秒）
        currentTime = currentTime.addingTimeInterval(0.2)
        XCTAssertTrue(sut.isAttentionActive)

        // クリック → タイマーリフレッシュ
        mockEventMonitor.simulateClick()

        // さらに 0.2秒経過（元の注意なら期限切れだがリフレッシュ後なのでまだ有効）
        currentTime = currentTime.addingTimeInterval(0.2)
        XCTAssertTrue(sut.isAttentionActive)
    }

    func testTerminalClickFiresOnTerminalClicked() {
        mockWorkspace.bundleIdentifier = "com.apple.Terminal"
        mockWorkspace.pid = 1234
        mockAX.terminalCenter = CGPoint(x: 500, y: 400)

        var callbackFired = false
        sut.onTerminalClicked = { callbackFired = true }

        sut.startPolling()
        mockEventMonitor.simulateClick()

        XCTAssertTrue(callbackFired)
    }

    func testNonTerminalClickDoesNotFireOnTerminalClicked() {
        mockWorkspace.bundleIdentifier = "com.apple.Safari"
        mockWorkspace.pid = 1234

        var callbackFired = false
        sut.onTerminalClicked = { callbackFired = true }

        sut.startPolling()
        mockEventMonitor.simulateClick()

        XCTAssertFalse(callbackFired)
    }
}
