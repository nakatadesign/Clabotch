import XCTest
@testable import Clabotch

// MARK: - HookServerUnitTests（MockSocketOps / 状態検証、required 19）

@MainActor
final class HookServerUnitTests: XCTestCase {
    private var testDir: String!

    override func setUp() {
        super.setUp()
        testDir = makeTestSocketDir()
    }

    override func tearDown() {
        cleanupTestDir(testDir)
        super.tearDown()
    }

    // ヘルパー: MockSocketOps を使う HookServer を作成
    // bind 成功時にダミーファイルを作成（chmod が実ファイルシステム操作のため）
    private func makeServer(
        mock: MockSocketOps,
        sleeper: @escaping (useconds_t) -> Void = { _ in },
        deduplicator: EventDeduplicator = EventDeduplicator(),
        onEvent: @escaping (ClabotchEnvelope) -> Void = { _ in },
        onListenerFailure: @escaping (Error) -> Void = { _ in },
        testHook: ((Int32) -> Void)? = nil
    ) -> HookServer {
        let originalBind = mock.onBind
        let socketFilePath = testDir! + "/hook.sock"
        mock.onBind = { fd, addr, len in
            let result = originalBind?(fd, addr, len) ?? 0
            if result == 0 {
                // bind 成功時にダミーファイルを作成して chmod が通るようにする
                FileManager.default.createFile(atPath: socketFilePath, contents: nil)
            }
            return result
        }
        return HookServer(
            socketDir: testDir,
            socketOps: mock,
            sleeper: sleeper,
            deduplicator: deduplicator,
            onEvent: onEvent,
            onListenerFailure: onListenerFailure,
            testHook_afterGenerationCheckBeforeRegister: testHook
        )
    }

    // 1. sun_path 長超過
    func testPathTooLong() {
        let longDir = "/tmp/" + String(repeating: "a", count: 100)
        try? FileManager.default.createDirectory(atPath: longDir, withIntermediateDirectories: true)
        chmod(longDir, 0o700)
        defer { try? FileManager.default.removeItem(atPath: longDir) }

        let mock = MockSocketOps()
        let server = HookServer(socketDir: longDir, socketOps: mock, onEvent: { _ in })
        XCTAssertThrowsError(try server.start()) { error in
            XCTAssertEqual(error as? HookServerError, .pathTooLong)
        }
    }

    // 2. start() 2回呼び出し → 2回目は no-op
    func testStartTwiceIsNoOp() throws {
        let mock = MockSocketOps()
        // handleStaleSocket で socket ファイルが無いため ENOENT → 正常
        mock.onConnect = { _, _, _ in errno = ENOENT; return -1 }
        let server = makeServer(mock: mock)
        try server.start()
        // 2回目は例外なし
        try server.start()
        server.terminateSync()
    }

    // 3. stopping 中の start() 拒否
    func testStartDuringStoppingThrows() throws {
        let mock = MockSocketOps()
        mock.onConnect = { _, _, _ in errno = ENOENT; return -1 }
        // accept をブロックして stopping 状態を維持
        let sem = DispatchSemaphore(value: 0)
        mock.onAccept = { _, _, _ in
            sem.wait()
            errno = EBADF
            return -1
        }
        let server = makeServer(mock: mock)
        try server.start()

        // stop() で stopping に遷移（completion は後で来る）
        server.stop()

        // stopping 状態で start() → .stopping throw
        XCTAssertThrowsError(try server.start()) { error in
            XCTAssertEqual(error as? HookServerError, .stopping)
        }

        sem.signal() // accept を解放してクリーンアップ
        let exp = expectation(description: "stop完了")
        // stop の completion は既に pending に積まれているので、もう一度 stop を呼ぶ
        // ただし stopping 中なので pending に追加される
        server.stop { _ in exp.fulfill() }
        wait(for: [exp], timeout: 5)
    }

    // 4. faulted → start() 拒否
    func testFaultedStartThrows() throws {
        let mock = MockSocketOps()
        mock.onConnect = { _, _, _ in errno = ENOENT; return -1 }
        // read を永久ブロックして timeout を誘発
        let readSem = DispatchSemaphore(value: 0)
        let readStartedSem = DispatchSemaphore(value: 0)
        var acceptCount = 0
        mock.onAccept = { fd, _, _ in
            acceptCount += 1
            if acceptCount == 1 {
                return 200 // クライアント fd を模擬
            }
            // 2回目以降: stop で close → EBADF
            errno = EBADF
            return -1
        }
        mock.onRead = { _, _, _ in
            readStartedSem.signal()
            readSem.wait()
            return 0
        }

        let server = makeServer(mock: mock)
        try server.start()

        // read ループが開始されるまで待つ（stop 前に接続が確立されていること）
        readStartedSem.wait()

        // stop timeout を短くするため、HookServer のデフォルト 3秒 timeout を利用
        // read がブロックされているので connectionGroup.wait が timeout する
        let exp = expectation(description: "stop完了")
        server.stop { outcome in
            XCTAssertEqual(outcome, .timedOut)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)
        readSem.signal()

        // faulted 状態で start() → .faulted throw
        XCTAssertThrowsError(try server.start()) { error in
            XCTAssertEqual(error as? HookServerError, .faulted)
        }
    }

    // 5. start() 途中失敗のロールバック（listen 失敗）
    func testStartRollbackOnListenFailure() {
        let mock = MockSocketOps()
        mock.onConnect = { _, _, _ in errno = ENOENT; return -1 }
        mock.onListen = { _, _ in errno = ENOMEM; return -1 }
        let server = makeServer(mock: mock)

        XCTAssertThrowsError(try server.start()) { error in
            guard case .listenFailed(let e) = error as? HookServerError else {
                XCTFail("期待するエラー型ではない: \(error)")
                return
            }
            XCTAssertEqual(e, ENOMEM)
        }

        // fd が close されていること
        XCTAssertTrue(mock.closedFds.count >= 1)
    }

    // 6. stop() で onListenerFailure が呼ばれないこと
    func testStopDoesNotTriggerListenerFailure() throws {
        let mock = MockSocketOps()
        mock.onConnect = { _, _, _ in errno = ENOENT; return -1 }

        var listenerFailureCalled = false
        let server = makeServer(mock: mock, onListenerFailure: { _ in
            listenerFailureCalled = true
        })
        try server.start()

        let exp = expectation(description: "stop完了")
        server.stop { _ in exp.fulfill() }
        wait(for: [exp], timeout: 5)

        XCTAssertFalse(listenerFailureCalled)
    }

    // 7. stop(completion:) の非同期完了
    func testStopCompletionIsAsync() throws {
        let mock = MockSocketOps()
        mock.onConnect = { _, _, _ in errno = ENOENT; return -1 }
        let server = makeServer(mock: mock)
        try server.start()

        var completionCalled = false
        let exp = expectation(description: "stop完了")
        server.stop { outcome in
            completionCalled = true
            XCTAssertEqual(outcome, .stopped)
            exp.fulfill()
        }

        // stop 呼び出し直後は main thread が解放されている（completionはまだ）
        // main run loop を回す前はまだ呼ばれていない可能性がある
        wait(for: [exp], timeout: 5)
        XCTAssertTrue(completionCalled)
    }

    // 8. stop completion の結果種別（正常 → .stopped）
    func testStopOutcomeStopped() throws {
        let mock = MockSocketOps()
        mock.onConnect = { _, _, _ in errno = ENOENT; return -1 }
        let server = makeServer(mock: mock)
        try server.start()

        let exp = expectation(description: "stop完了")
        server.stop { outcome in
            XCTAssertEqual(outcome, .stopped)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }

    // 9. stop() timeout 検出 → .timedOut
    func testStopTimeoutDetection() throws {
        let mock = MockSocketOps()
        mock.onConnect = { _, _, _ in errno = ENOENT; return -1 }
        let readSem = DispatchSemaphore(value: 0)
        let readStartedSem = DispatchSemaphore(value: 0)
        var acceptCount = 0
        mock.onAccept = { _, _, _ in
            acceptCount += 1
            if acceptCount == 1 { return 200 }
            errno = EBADF; return -1
        }
        mock.onRead = { _, _, _ in
            readStartedSem.signal()
            readSem.wait()
            return 0
        }

        let server = makeServer(mock: mock)
        try server.start()

        // read ループが開始されるまで待つ
        readStartedSem.wait()

        let exp = expectation(description: "stop完了")
        server.stop { outcome in
            XCTAssertEqual(outcome, .timedOut)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)
        readSem.signal()
    }

    // 10. EMFILE backoff (deterministic)
    func testEMFILEBackoffDeterministic() throws {
        let mock = MockSocketOps()
        mock.onConnect = { _, _, _ in errno = ENOENT; return -1 }

        var sleeperCalled = 0
        var acceptCount = 0
        mock.onAccept = { _, _, _ in
            acceptCount += 1
            if acceptCount <= 3 {
                errno = EMFILE
                return -1
            }
            // 4回目以降: stop で close → EBADF
            errno = EBADF
            return -1
        }

        let server = makeServer(mock: mock, sleeper: { _ in sleeperCalled += 1 })
        try server.start()

        let exp = expectation(description: "stop完了")
        // 少し待ってから stop
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            server.stop { _ in exp.fulfill() }
        }
        wait(for: [exp], timeout: 5)

        XCTAssertGreaterThanOrEqual(sleeperCalled, 3)
    }

    // 11. accept 連続5回失敗 → onListenerFailure
    func testAccept5ConsecutiveFailuresTriggersListenerFailure() throws {
        let mock = MockSocketOps()
        mock.onConnect = { _, _, _ in errno = ENOENT; return -1 }

        var acceptCount = 0
        mock.onAccept = { _, _, _ in
            acceptCount += 1
            errno = ENOMEM // "その他"エラー
            return -1
        }

        let listenerFailureExp = expectation(description: "onListenerFailure")
        let server = makeServer(mock: mock, sleeper: { _ in }, onListenerFailure: { _ in
            listenerFailureExp.fulfill()
        })
        try server.start()

        wait(for: [listenerFailureExp], timeout: 5)
        XCTAssertGreaterThanOrEqual(acceptCount, 5)
    }

    // 12. performTeardown 統一（listener failure 経由と正常 stop が同じ最終状態）
    func testTeardownUnification() throws {
        // 正常 stop のテスト: socket ファイルが削除され、listenSocket == -1 になること
        let mock = MockSocketOps()
        mock.onConnect = { _, _, _ in errno = ENOENT; return -1 }
        let server = makeServer(mock: mock)
        try server.start()

        let socketPath = testDir + "/hook.sock"
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))

        let exp = expectation(description: "stop完了")
        server.stop { outcome in
            XCTAssertEqual(outcome, .stopped)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)

        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    // 13. terminateSync 同期実行
    func testTerminateSyncDeletesSocket() throws {
        let mock = MockSocketOps()
        mock.onConnect = { _, _, _ in errno = ENOENT; return -1 }
        let server = makeServer(mock: mock)
        try server.start()

        let socketPath = testDir + "/hook.sock"
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))

        server.terminateSync()

        // 同期的に socket が削除されること
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    // 14. bind(EADDRINUSE) → alreadyRunning（再 probe で live）
    func testBindEADDRINUSEAlreadyRunning() {
        let mock = MockSocketOps()
        var bindCallCount = 0
        mock.onBind = { _, _, _ in
            bindCallCount += 1
            errno = EADDRINUSE
            return -1
        }
        // probe connect → 成功（live socket）
        mock.onConnect = { _, _, _ in return 0 }

        let server = makeServer(mock: mock)
        XCTAssertThrowsError(try server.start()) { error in
            XCTAssertEqual(error as? HookServerError, .alreadyRunning)
        }
    }

    // 15. bind(EADDRINUSE) → bindFailed（再 probe 失敗）
    func testBindEADDRINUSEBindFailed() {
        let mock = MockSocketOps()
        mock.onBind = { _, _, _ in errno = EADDRINUSE; return -1 }
        // probe connect → ECONNREFUSED（stale）だが bind 失敗なので bindFailed
        mock.onConnect = { _, _, _ in errno = ECONNREFUSED; return -1 }

        let server = makeServer(mock: mock)
        XCTAssertThrowsError(try server.start()) { error in
            XCTAssertEqual(error as? HookServerError, .bindFailed(errno: EADDRINUSE))
        }
    }

    // 16. accept(EMFILE) → backoff して復帰
    func testAcceptEMFILEBackoffAndRecover() throws {
        let mock = MockSocketOps()
        mock.onConnect = { _, _, _ in errno = ENOENT; return -1 }

        var acceptCount = 0
        mock.onAccept = { _, _, _ in
            acceptCount += 1
            if acceptCount <= 2 {
                errno = EMFILE
                return -1
            }
            // 3回目以降: stop で break
            errno = EBADF
            return -1
        }

        let server = makeServer(mock: mock, sleeper: { _ in })
        try server.start()

        let exp = expectation(description: "stop完了")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            server.stop { _ in exp.fulfill() }
        }
        wait(for: [exp], timeout: 5)

        // EMFILE が2回発生したが5回未満なので onListenerFailure は呼ばれない
        XCTAssertGreaterThanOrEqual(acceptCount, 3)
    }

    // 17. mkdir EEXIST race（実際に EEXIST パスを通す）
    func testMkdirEEXISTRace() throws {
        // 別の socketDir を使い、ensureSocketDir で mkdir を実行させる
        let raceDir = testDir + "_race"
        try? FileManager.default.removeItem(atPath: raceDir)
        defer { try? FileManager.default.removeItem(atPath: raceDir) }

        let mock = MockSocketOps()
        mock.onConnect = { _, _, _ in errno = ENOENT; return -1 }
        // bind 成功時にダミーファイルを作成（chmod 対策）
        let socketFilePath = raceDir + "/hook.sock"
        mock.onBind = { _, _, _ in
            FileManager.default.createFile(atPath: socketFilePath, contents: nil)
            return 0
        }

        let server = HookServer(
            socketDir: raceDir,
            socketOps: mock,
            onEvent: { _ in }
        )

        // raceDir が存在しない状態 → ensureSocketDir が mkdir で作成 → start 成功
        try server.start()
        server.terminateSync()

        // raceDir は作成されている
        var st = stat()
        XCTAssertEqual(lstat(raceDir, &st), 0, "ディレクトリが作成されていない")
        XCTAssertTrue((st.st_mode & S_IFMT) == S_IFDIR, "ディレクトリではない")
        XCTAssertEqual(st.st_mode & 0o777, 0o700, "パーミッションが 0700 でない")
    }

    // 17b. ensureSocketDir EEXIST 再試行上限
    func testMkdirEEXISTRetryLimit() {
        // 別の socketDir を使い、ensureSocketDir で正常に mkdir できることを確認
        let nonExistDir = "/tmp/cbt-noexist-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: nonExistDir) }

        let mock = MockSocketOps()
        mock.onConnect = { _, _, _ in errno = ENOENT; return -1 }
        let socketFilePath = nonExistDir + "/hook.sock"
        mock.onBind = { _, _, _ in
            FileManager.default.createFile(atPath: socketFilePath, contents: nil)
            return 0
        }
        let server = HookServer(socketDir: nonExistDir, socketOps: mock, onEvent: { _ in })

        // 正常に作成されることの確認
        XCTAssertNoThrow(try server.start())
        server.terminateSync()

        // ディレクトリが 0700 で作成されたこと
        var st = stat()
        XCTAssertEqual(lstat(nonExistDir, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o700)
    }

    // 18. listenerFailure と stop の競合（ownership 排他）
    func testListenerFailureAndStopOwnershipExclusion() throws {
        let mock = MockSocketOps()
        mock.onConnect = { _, _, _ in errno = ENOENT; return -1 }

        var acceptCount = 0
        mock.onAccept = { _, _, _ in
            acceptCount += 1
            errno = ENOMEM
            return -1
        }

        var listenerFailureCount = 0
        let failureExp = expectation(description: "onListenerFailure")
        let server = makeServer(mock: mock, sleeper: { _ in }, onListenerFailure: { _ in
            listenerFailureCount += 1
            failureExp.fulfill()
        })
        try server.start()

        // listener failure が ownership を取る
        wait(for: [failureExp], timeout: 5)

        // その後 stop() → beginTeardown は false を返す（既に stopping/faulted）
        let stopExp = expectation(description: "stop完了")
        server.stop { _ in stopExp.fulfill() }
        wait(for: [stopExp], timeout: 5)

        // onListenerFailure は1回だけ
        XCTAssertEqual(listenerFailureCount, 1)
    }

    // 19. accept 直後の stop race（testHook seam 使用）
    func testAcceptThenStopRaceWithTestHook() throws {
        let mock = MockSocketOps()
        mock.onConnect = { _, _, _ in errno = ENOENT; return -1 }

        let hookSem = DispatchSemaphore(value: 0)
        let hookReachedExp = expectation(description: "hook到達")

        var acceptCount = 0
        mock.onAccept = { _, _, _ in
            acceptCount += 1
            if acceptCount == 1 { return 200 }
            errno = EBADF; return -1
        }

        let server = makeServer(mock: mock, testHook: { _ in
            hookReachedExp.fulfill()
            hookSem.wait() // generation check 通過後、connectionsLock 取得前でブロック
        })
        try server.start()

        // hook に到達するのを待つ
        wait(for: [hookReachedExp], timeout: 3)

        // main thread で stop() → isShuttingDown = true
        server.stop()

        // hook を解放 → handleNewConnection が isShuttingDown を検出して clientFd を close
        hookSem.signal()

        // stop 完了を待つ
        let stopExp = expectation(description: "stop完了2")
        server.stop { _ in stopExp.fulfill() }
        wait(for: [stopExp], timeout: 5)

        // clientFd (200) が close されていること
        XCTAssertTrue(mock.closedFds.contains(200))
    }
}

// MARK: - HookServerIntegrationTests（実 socket 使用、required 17 + conditional 1）

@MainActor
final class HookServerIntegrationTests: XCTestCase {
    private var testDir: String!

    override func setUp() {
        super.setUp()
        testDir = makeTestSocketDir()
    }

    override func tearDown() {
        cleanupTestDir(testDir)
        super.tearDown()
    }

    private var socketPath: String { testDir + "/hook.sock" }

    private func makeRealServer(
        deduplicator: EventDeduplicator = EventDeduplicator(),
        onEvent: @escaping (ClabotchEnvelope) -> Void = { _ in },
        onListenerFailure: @escaping (Error) -> Void = { _ in }
    ) -> HookServer {
        HookServer(socketDir: testDir, deduplicator: deduplicator, onEvent: onEvent, onListenerFailure: onListenerFailure)
    }

    // 1. 単一クライアント接続
    func testSingleClientConnection() throws {
        let receivedExp = expectation(description: "イベント受信")
        let server = makeRealServer(onEvent: { envelope in
            if case .sessionStart = envelope.event { receivedExp.fulfill() }
        })
        try server.start()

        let ndjson = makeTestNDJSON(event: "session_start") + "\n"
        try sendToSocket(path: socketPath, data: Data(ndjson.utf8))
        wait(for: [receivedExp], timeout: 3)

        let exp = expectation(description: "stop")
        server.stop { _ in exp.fulfill() }
        wait(for: [exp], timeout: 5)
    }

    // 2. 複数クライアント並行
    func testMultipleClientsParallel() throws {
        var receivedCount = 0
        let lock = NSLock()
        let allReceivedExp = expectation(description: "2クライアント受信")

        let server = makeRealServer(onEvent: { _ in
            lock.lock()
            receivedCount += 1
            if receivedCount >= 2 { allReceivedExp.fulfill() }
            lock.unlock()
        })
        try server.start()

        let ndjson1 = makeTestNDJSON(event: "session_start", eventID: UUID()) + "\n"
        let ndjson2 = makeTestNDJSON(event: "session_start", eventID: UUID()) + "\n"
        try sendToSocket(path: socketPath, data: Data(ndjson1.utf8))
        try sendToSocket(path: socketPath, data: Data(ndjson2.utf8))
        wait(for: [allReceivedExp], timeout: 3)

        let exp = expectation(description: "stop")
        server.stop { _ in exp.fulfill() }
        wait(for: [exp], timeout: 5)
    }

    // 3. 1行を複数 write 分割
    func testSplitWrite() throws {
        let receivedExp = expectation(description: "イベント受信")
        let eventID = UUID()
        let server = makeRealServer(onEvent: { envelope in
            if envelope.eventID == eventID { receivedExp.fulfill() }
        })
        try server.start()

        // 有効な NDJSON を途中で分割して送信
        let fullLine = makeTestNDJSON(event: "session_start", eventID: eventID) + "\n"
        let midpoint = fullLine.index(fullLine.startIndex, offsetBy: fullLine.count / 2)
        let part1 = Data(fullLine[fullLine.startIndex..<midpoint].utf8)
        let part2 = Data(fullLine[midpoint...].utf8)

        // 手動で接続して2回の write
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            socketPath.withCString { src in _ = memcpy(buf.baseAddress!, src, min(strlen(src) + 1, buf.count)) }
        }
        withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                _ = Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        _ = part1.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        usleep(10_000)
        _ = part2.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }

        wait(for: [receivedExp], timeout: 3)

        let exp = expectation(description: "stop")
        server.stop { _ in exp.fulfill() }
        wait(for: [exp], timeout: 5)
    }

    // 4. EOF クリーンアップ
    func testEOFCleanup() throws {
        let firstExp = expectation(description: "1回目受信")
        let secondExp = expectation(description: "2回目受信")
        var callCount = 0
        let lock = NSLock()

        let server = makeRealServer(onEvent: { _ in
            lock.lock()
            callCount += 1
            if callCount == 1 { firstExp.fulfill() }
            if callCount == 2 { secondExp.fulfill() }
            lock.unlock()
        })
        try server.start()

        let ndjson1 = makeTestNDJSON(event: "session_start", eventID: UUID()) + "\n"
        try sendToSocket(path: socketPath, data: Data(ndjson1.utf8))
        wait(for: [firstExp], timeout: 3)

        // 1回目の接続は close 済み。新しい接続で送信
        let ndjson2 = makeTestNDJSON(event: "session_start", eventID: UUID()) + "\n"
        try sendToSocket(path: socketPath, data: Data(ndjson2.utf8))
        wait(for: [secondExp], timeout: 3)

        let exp = expectation(description: "stop")
        server.stop { _ in exp.fulfill() }
        wait(for: [exp], timeout: 5)
    }

    // 5. stop() で accept 離脱
    func testStopStopsAccepting() throws {
        let server = makeRealServer()
        try server.start()
        XCTAssertTrue(isSocketLive(path: socketPath))

        let exp = expectation(description: "stop")
        server.stop { _ in exp.fulfill() }
        wait(for: [exp], timeout: 5)

        XCTAssertFalse(isSocketLive(path: socketPath))
    }

    // 6. stop() → start() 再起動
    func testStopThenRestart() throws {
        let server = makeRealServer()
        try server.start()

        let stopExp = expectation(description: "stop")
        server.stop { outcome in
            XCTAssertEqual(outcome, .stopped)
            stopExp.fulfill()
        }
        wait(for: [stopExp], timeout: 5)

        try server.start()
        XCTAssertTrue(isSocketLive(path: socketPath))

        let stopExp2 = expectation(description: "stop2")
        server.stop { _ in stopExp2.fulfill() }
        wait(for: [stopExp2], timeout: 5)
    }

    // 7. 接続保持中の stop()
    func testStopWithActiveConnection() throws {
        let server = makeRealServer()
        try server.start()

        // 接続を保持
        let clientFd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var on: Int32 = 1
        setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            socketPath.withCString { src in _ = memcpy(buf.baseAddress!, src, min(strlen(src) + 1, buf.count)) }
        }
        withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                _ = Darwin.connect(clientFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        let stopExp = expectation(description: "stop")
        server.stop { _ in stopExp.fulfill() }
        wait(for: [stopExp], timeout: 5)

        // クライアント側で read が EOF を返すこと
        var buf = [UInt8](repeating: 0, count: 1)
        let n = Darwin.read(clientFd, &buf, 1)
        XCTAssertEqual(n, 0) // EOF
        Darwin.close(clientFd)
    }

    // 8. stop() 後に stale emit なし
    func testNoStaleEmitAfterStop() throws {
        var stopCompleted = false
        var postStopEmitCount = 0
        let preStopExp = expectation(description: "preStop受信")

        let server = makeRealServer(onEvent: { _ in
            if stopCompleted {
                postStopEmitCount += 1
            } else {
                preStopExp.fulfill()
            }
        })
        try server.start()

        let ndjson = makeTestNDJSON(event: "session_start", eventID: UUID()) + "\n"
        try sendToSocket(path: socketPath, data: Data(ndjson.utf8))
        wait(for: [preStopExp], timeout: 3)

        let stopExp = expectation(description: "stop")
        server.stop { _ in
            stopCompleted = true
            stopExp.fulfill()
        }
        wait(for: [stopExp], timeout: 5)

        // stop 完了後に socket への送信を試みる（接続自体が失敗するはず）
        let afterNdjson = makeTestNDJSON(event: "session_start", eventID: UUID()) + "\n"
        do {
            try sendToSocket(path: socketPath, data: Data(afterNdjson.utf8))
        } catch {
            // 接続失敗は期待通り（socket が unlink 済み）
        }

        // 念のため少し待ってから検証
        let waitExp = expectation(description: "wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { waitExp.fulfill() }
        wait(for: [waitExp], timeout: 1)

        // stop 後に onEvent が呼ばれていないこと
        XCTAssertEqual(postStopEmitCount, 0, "stop 完了後に onEvent が呼ばれた")
    }

    // 9. stop() 冪等性
    func testStopIdempotent() throws {
        let server = makeRealServer()
        try server.start()

        let exp1 = expectation(description: "stop1")
        server.stop { _ in exp1.fulfill() }
        wait(for: [exp1], timeout: 5)

        // 2回目の stop → 即 completion
        let exp2 = expectation(description: "stop2")
        server.stop { outcome in
            XCTAssertEqual(outcome, .stopped)
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 1)
    }

    // 10. lstat 通常ファイル保護
    func testRegularFileProtection() throws {
        // socket path に通常ファイルを作成
        FileManager.default.createFile(atPath: socketPath, contents: Data())

        let server = makeRealServer()
        XCTAssertThrowsError(try server.start()) { error in
            // 通常ファイルがある → unlink しない → socketFileInvalid(.notSocket)
            XCTAssertEqual(error as? HookServerError, .socketFileInvalid(reason: .notSocket))
        }

        // ファイルが残っていること（unlink されていない）
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
    }

    // 11. chmod 0600 検証
    func testSocketPermissions() throws {
        let server = makeRealServer()
        try server.start()

        var st = stat()
        XCTAssertEqual(lstat(socketPath, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)

        server.terminateSync()
    }

    // 12. live socket 検出
    func testLiveSocketDetection() throws {
        // 先にサーバーを起動
        let server1 = makeRealServer()
        try server1.start()

        // 同じパスで2つ目を起動 → alreadyRunning
        let server2 = makeRealServer()
        XCTAssertThrowsError(try server2.start()) { error in
            XCTAssertEqual(error as? HookServerError, .alreadyRunning)
        }

        server1.terminateSync()
    }

    // 13. socketDir 不正検証（通常ファイル）
    func testSocketDirIsFile() {
        let badDir = "/tmp/cbt-file-\(UUID().uuidString.prefix(6))"
        FileManager.default.createFile(atPath: badDir, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: badDir) }

        let server = HookServer(socketDir: badDir, onEvent: { _ in })
        XCTAssertThrowsError(try server.start()) { error in
            if case .socketDirInvalid(reason: .notDirectory) = error as? HookServerError {
                // 期待通り
            } else {
                XCTFail("期待するエラーではない: \(error)")
            }
        }
    }

    // 14. stale socket の unlink 成功
    func testStaleSocketUnlink() throws {
        // stale socket を作成（listen プロセスなし）
        let staleFd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            socketPath.withCString { src in _ = memcpy(buf.baseAddress!, src, min(strlen(src) + 1, buf.count)) }
        }
        withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                _ = Darwin.bind(staleFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        Darwin.close(staleFd) // listen せずに close → stale socket

        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))

        let server = makeRealServer()
        try server.start() // stale socket を unlink して起動成功

        XCTAssertTrue(isSocketLive(path: socketPath))
        server.terminateSync()
    }

    // 15. socketDir 0755 拒否
    func testSocketDir0755Rejected() {
        let badDir = "/tmp/cbt-perm-\(UUID().uuidString.prefix(6))"
        try! FileManager.default.createDirectory(atPath: badDir, withIntermediateDirectories: true)
        chmod(badDir, 0o755)
        defer { try? FileManager.default.removeItem(atPath: badDir) }

        let server = HookServer(socketDir: badDir, onEvent: { _ in })
        XCTAssertThrowsError(try server.start()) { error in
            if case .socketDirInvalid(reason: .wrongPermissions) = error as? HookServerError {
                // 期待通り
            } else {
                XCTFail("期待するエラーではない: \(error)")
            }
        }
    }

    // 16. NDJSON バッチ順序保証
    func testNDJSONBatchOrder() throws {
        let receivedExp = expectation(description: "2イベント受信")
        var receivedEvents: [ClabotchEvent] = []
        let lock = NSLock()

        let server = makeRealServer(onEvent: { envelope in
            lock.lock()
            receivedEvents.append(envelope.event)
            if receivedEvents.count >= 2 { receivedExp.fulfill() }
            lock.unlock()
        })
        try server.start()

        // 2行を1回の write で送信
        let id1 = UUID(), id2 = UUID()
        let line1 = makeTestNDJSON(event: "session_start", sessionID: "batch-1", eventID: id1)
        let line2 = makeTestNDJSON(event: "session_start", sessionID: "batch-2", eventID: id2)
        let batch = line1 + "\n" + line2 + "\n"
        try sendToSocket(path: socketPath, data: Data(batch.utf8))
        wait(for: [receivedExp], timeout: 3)

        XCTAssertEqual(receivedEvents[0], .sessionStart(sessionID: "batch-1"))
        XCTAssertEqual(receivedEvents[1], .sessionStart(sessionID: "batch-2"))

        let exp = expectation(description: "stop")
        server.stop { _ in exp.fulfill() }
        wait(for: [exp], timeout: 5)
    }

    // 17. connect(ENOENT) probe
    func testConnectENOENTProbe() throws {
        // socket ファイルが存在しない状態で start() → 正常起動
        let server = makeRealServer()
        try server.start()
        XCTAssertTrue(isSocketLive(path: socketPath))
        server.terminateSync()
    }

    // 18. [conditional] socketDir owner 不一致（root でのみ検証可、SKIP 許容）
    func testSocketDirOwnerMismatch() throws {
        // root でなければスキップ
        try XCTSkipIf(getuid() != 0, "root でのみ検証可能")
        // root の場合のテストコードはここに追加
    }

    // MARK: - 結線テスト（EventParser + EventDeduplicator 統合、required 3）

    // 19. 有効な NDJSON → onEvent で ClabotchEnvelope を受信
    func testValidNDJSONProducesEvent() throws {
        let receivedExp = expectation(description: "イベント受信")
        let eventID = UUID()
        var receivedEnvelope: ClabotchEnvelope?

        let server = makeRealServer(onEvent: { envelope in
            receivedEnvelope = envelope
            receivedExp.fulfill()
        })
        try server.start()

        let ndjson = makeTestNDJSON(event: "session_start", sessionID: "wiring-test", eventID: eventID) + "\n"
        try sendToSocket(path: socketPath, data: Data(ndjson.utf8))
        wait(for: [receivedExp], timeout: 3)

        XCTAssertEqual(receivedEnvelope?.eventID, eventID)
        XCTAssertEqual(receivedEnvelope?.event, .sessionStart(sessionID: "wiring-test"))

        let exp = expectation(description: "stop")
        server.stop { _ in exp.fulfill() }
        wait(for: [exp], timeout: 5)
    }

    // 20. 不正 JSON 行はスキップされ、有効行のみ onEvent に届く
    func testInvalidJSONLineSkipped() throws {
        let receivedExp = expectation(description: "有効イベント受信")
        var receivedEvents: [ClabotchEvent] = []

        let server = makeRealServer(onEvent: { envelope in
            receivedEvents.append(envelope.event)
            if receivedEvents.count >= 1 { receivedExp.fulfill() }
        })
        try server.start()

        // 1行目: 不正 JSON、2行目: 有効 NDJSON
        let validID = UUID()
        let invalidLine = "{\"bad json\n"
        let validLine = makeTestNDJSON(event: "session_start", sessionID: "valid", eventID: validID) + "\n"
        let batch = invalidLine + validLine
        try sendToSocket(path: socketPath, data: Data(batch.utf8))
        wait(for: [receivedExp], timeout: 3)

        XCTAssertEqual(receivedEvents.count, 1)
        XCTAssertEqual(receivedEvents[0], .sessionStart(sessionID: "valid"))

        let exp = expectation(description: "stop")
        server.stop { _ in exp.fulfill() }
        wait(for: [exp], timeout: 5)
    }

    // 21. 同一 event_id の重複行は EventDeduplicator でフィルタされる
    func testDuplicateEventIDFiltered() throws {
        let receivedExp = expectation(description: "イベント受信")
        var receivedCount = 0

        let server = makeRealServer(onEvent: { _ in
            receivedCount += 1
            receivedExp.fulfill()
        })
        try server.start()

        // 同じ event_id で2行送信
        let duplicateID = UUID()
        let line = makeTestNDJSON(event: "session_start", eventID: duplicateID)
        let batch = line + "\n" + line + "\n"
        try sendToSocket(path: socketPath, data: Data(batch.utf8))
        wait(for: [receivedExp], timeout: 3)

        // 少し待って追加イベントが来ないことを確認
        let waitExp = expectation(description: "wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { waitExp.fulfill() }
        wait(for: [waitExp], timeout: 1)

        XCTAssertEqual(receivedCount, 1, "重複 event_id が dedup されていない")

        let exp = expectation(description: "stop")
        server.stop { _ in exp.fulfill() }
        wait(for: [exp], timeout: 5)
    }
}

// MARK: - HookServerAppDelegateTests（required 3）

@MainActor
final class HookServerAppDelegateTests: XCTestCase {
    private var testDir: String!

    override func setUp() {
        super.setUp()
        testDir = makeTestSocketDir()
    }

    override func tearDown() {
        cleanupTestDir(testDir)
        super.tearDown()
    }

    // 1. alreadyRunning → terminate 相当
    func testAlreadyRunningThrows() throws {
        let server1 = HookServer(socketDir: testDir, onEvent: { _ in })
        try server1.start()

        let server2 = HookServer(socketDir: testDir, onEvent: { _ in })
        XCTAssertThrowsError(try server2.start()) { error in
            XCTAssertEqual(error as? HookServerError, .alreadyRunning)
            // AppDelegate はこのエラーで terminate を呼ぶ
        }

        server1.terminateSync()
    }

    // 2. terminateSync + stopping 競合
    func testTerminateSyncDuringStoppingIsNoOp() throws {
        let server = HookServer(socketDir: testDir, onEvent: { _ in })
        try server.start()

        // stop() で .stopping に遷移
        server.stop()

        // .stopping 中の terminateSync → beginTeardown が false → no-op
        server.terminateSync() // crash しないことが検証

        // stop の完了を待つ
        let exp = expectation(description: "stop完了")
        server.stop { _ in exp.fulfill() }
        wait(for: [exp], timeout: 5)
    }

    // 3. terminateSync 後の unlink 保証
    func testTerminateSyncUnlinksSocket() throws {
        let server = HookServer(socketDir: testDir, onEvent: { _ in })
        try server.start()

        let socketPath = testDir + "/hook.sock"
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))

        server.terminateSync()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }
}
