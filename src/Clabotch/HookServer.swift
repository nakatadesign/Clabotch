import Foundation
import os.log

/// HookServer のエラー型。switch で網羅的に処理可能。
enum HookServerError: Error, Equatable {
    // ライフサイクル
    case alreadyRunning
    case faulted
    case stopping
    // socket 作成
    case socketCreationFailed(errno: Int32)
    case bindFailed(errno: Int32)
    case listenFailed(errno: Int32)
    case chmodFailed(errno: Int32)
    // socket ディレクトリ
    case mkdirFailed(errno: Int32)
    case socketDirInvalid(reason: SocketDirInvalidReason)
    // socket ファイル
    case socketFileInvalid(reason: SocketFileInvalidReason)
    // ファイルシステム操作
    case statFailed(path: String, errno: Int32)
    case unlinkFailed(path: String, errno: Int32)
    // probe
    case socketProbeError(errno: Int32)
    case probeSocketCreationFailed(errno: Int32)
    // パス
    case pathTooLong
}

/// socketDir が不正な理由
enum SocketDirInvalidReason: Equatable {
    case notDirectory
    case wrongOwner(uid: uid_t)
    case wrongPermissions(mode: mode_t)
}

/// socket ファイルが不正な理由
enum SocketFileInvalidReason: Equatable {
    case notSocket
    case wrongOwner(uid: uid_t)
}

/// teardown の理由
enum TeardownReason {
    case normalStop
    case listenerFailure(Error)
}

/// Unix domain socket で hook スクリプトからの NDJSON イベントを受信するサーバー。
/// main thread で start()/stop()/terminateSync() を呼ぶ。
final class HookServer {
    private let socketPath: String
    private let socketDir: String
    private let socketOps: SocketOps
    private let sleeper: (useconds_t) -> Void
    private let deduplicator: EventDeduplicator
    private let onEvent: (ClabotchEnvelope) -> Void
    private let onListenerFailure: (Error) -> Void
    private let testHook_afterGenerationCheckBeforeRegister: ((Int32) -> Void)?

    private var listenSocket: Int32 = -1

    private enum LifecycleState { case stopped, running, stopping, faulted }
    private var lifecycleState: LifecycleState = .stopped

    private let stateQueue = DispatchQueue(label: "com.clabotch.hookserver.state")
    private var generation: UInt64 = 0

    private let acceptQueue = DispatchQueue(label: "com.clabotch.accept")
    private let controlQueue = DispatchQueue(label: "com.clabotch.hookserver.control")
    private let acceptGroup = DispatchGroup()
    private let connectionGroup = DispatchGroup()
    private let connectionsLock = NSLock()

    private final class Connection {
        let fd: Int32
        private let ops: SocketOps
        private var isClosed = false
        private let lock = NSLock()

        init(fd: Int32, ops: SocketOps) { self.fd = fd; self.ops = ops }

        func closeOnce() {
            lock.lock()
            defer { lock.unlock() }
            guard !isClosed else { return }
            isClosed = true
            _ = ops.shutdown(fd, SHUT_RDWR)
            _ = ops.close(fd)
        }
    }
    private var activeConnections: [Connection] = []
    private var isShuttingDown = false
    private var pendingStopCompletions: [((StopOutcome) -> Void)] = []

    enum StopOutcome { case stopped, timedOut }

    init(socketDir: String,
         socketName: String = "hook.sock",
         socketOps: SocketOps = RealSocketOps(),
         sleeper: @escaping (useconds_t) -> Void = { usleep($0) },
         deduplicator: EventDeduplicator = EventDeduplicator(),
         onEvent: @escaping (ClabotchEnvelope) -> Void,
         onListenerFailure: @escaping (Error) -> Void = { _ in },
         testHook_afterGenerationCheckBeforeRegister: ((Int32) -> Void)? = nil) {
        self.socketDir = socketDir
        self.socketPath = (socketDir as NSString).appendingPathComponent(socketName)
        self.socketOps = socketOps
        self.sleeper = sleeper
        self.deduplicator = deduplicator
        self.onEvent = onEvent
        self.onListenerFailure = onListenerFailure
        self.testHook_afterGenerationCheckBeforeRegister = testHook_afterGenerationCheckBeforeRegister
    }

    // MARK: - ライフサイクル

    /// main thread 限定。.stopped 以外なら no-op(.running) / throw(.stopping/.faulted)。
    func start() throws {
        dispatchPrecondition(condition: .onQueue(.main))

        switch lifecycleState {
        case .running:
            return
        case .stopping:
            throw HookServerError.stopping
        case .faulted:
            throw HookServerError.faulted
        case .stopped:
            break
        }

        // socketDir の検証・作成
        try ensureSocketDir()

        // stale socket の判定
        try handleStaleSocket()

        // listen socket 作成
        let fd = socketOps.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw HookServerError.socketCreationFailed(errno: errno)
        }

        // FD_CLOEXEC
        if fcntl(fd, F_SETFD, FD_CLOEXEC) == -1 {
            os_log(.error, "FD_CLOEXEC 設定失敗（listen socket）: errno=%d", errno)
        }

        // sun_path 長検証 + bind
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= 104 else {
            _ = socketOps.close(fd)
            throw HookServerError.pathTooLong
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            socketPath.withCString { src in
                _ = memcpy(buf.baseAddress!, src, min(strlen(src) + 1, buf.count))
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                socketOps.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if bindResult != 0 {
            let bindErrno = errno
            _ = socketOps.close(fd)
            if bindErrno == EADDRINUSE {
                // 再 probe
                if probeSocketLive() {
                    throw HookServerError.alreadyRunning
                }
                throw HookServerError.bindFailed(errno: bindErrno)
            }
            throw HookServerError.bindFailed(errno: bindErrno)
        }

        // chmod 0600
        if chmod(socketPath, 0o600) != 0 {
            let chmodErrno = errno
            _ = socketOps.close(fd)
            unlink(socketPath)
            throw HookServerError.chmodFailed(errno: chmodErrno)
        }

        // listen
        if socketOps.listen(fd, 16) != 0 {
            let listenErrno = errno
            _ = socketOps.close(fd)
            unlink(socketPath)
            throw HookServerError.listenFailed(errno: listenErrno)
        }

        listenSocket = fd
        lifecycleState = .running

        // generation インクリメント + accept ループ開始
        let capturedGeneration = stateQueue.sync { () -> UInt64 in
            generation &+= 1
            return generation
        }

        acceptGroup.enter()
        acceptQueue.async { [capturedFd = fd, capturedGeneration] in
            defer { self.acceptGroup.leave() }
            self.acceptLoop(fd: capturedFd, generation: capturedGeneration)
        }
    }

    /// 非同期 stop。completion は main thread で呼ばれる。
    func stop(completion: @escaping (StopOutcome) -> Void = { _ in }) {
        dispatchPrecondition(condition: .onQueue(.main))

        switch lifecycleState {
        case .stopped:
            completion(.stopped)
            return
        case .faulted:
            completion(.timedOut)
            return
        case .stopping:
            pendingStopCompletions.append(completion)
            return
        case .running:
            break
        }

        guard beginTeardown(reason: .normalStop) else {
            completion(.stopped)
            return
        }
        performTeardown(reason: .normalStop, completion: completion)
    }

    /// applicationWillTerminate 専用。listen close + unlink を同期実行。
    func terminateSync() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard beginTeardown(reason: .normalStop) else { return }
        performTeardown(reason: .normalStop, completion: nil, skipDrain: true)
    }

    // MARK: - Teardown

    /// .running → .stopping を1回だけ取る（ownership 取得のみ）。
    private func beginTeardown(reason: TeardownReason) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard lifecycleState == .running else { return false }
        lifecycleState = .stopping
        return true
    }

    /// 唯一の cleanup パス。
    private func performTeardown(reason: TeardownReason, completion: ((StopOutcome) -> Void)?, skipDrain: Bool = false) {
        dispatchPrecondition(condition: .onQueue(.main))

        // step 1: generation インクリメント
        stateQueue.sync { generation &+= 1 }

        // step 2: isShuttingDown 設定
        connectionsLock.lock()
        isShuttingDown = true
        connectionsLock.unlock()

        // step 3: listen socket close
        if listenSocket >= 0 {
            _ = socketOps.shutdown(listenSocket, SHUT_RDWR)
            _ = socketOps.close(listenSocket)
        }

        // step 4: listenSocket リセット
        listenSocket = -1

        // step 5: socket ファイル unlink
        unlink(socketPath)

        // step 6: skipDrain なら return（terminateSync 用）
        if skipDrain { return }

        // step 7: controlQueue で非同期 drain
        let teardownReason = reason
        controlQueue.async {
            // 7a: accept ループ終了待ち
            let acceptResult = self.acceptGroup.wait(timeout: .now() + 3.0)

            // 7b: 全接続の snapshot → lock 解放後に closeOnce
            self.connectionsLock.lock()
            let snapshot = self.activeConnections
            self.connectionsLock.unlock()
            for conn in snapshot {
                conn.closeOnce()
            }

            // 7c: 全 connectionQueue 完了待ち
            let connResult = self.connectionGroup.wait(timeout: .now() + 3.0)

            // 7d: main thread で最終処理
            DispatchQueue.main.async {
                let timedOut = (acceptResult == .timedOut || connResult == .timedOut)
                let outcome: StopOutcome

                if timedOut {
                    self.lifecycleState = .faulted
                    os_log(.fault, "HookServer stop timeout")
                    outcome = .timedOut
                } else {
                    self.lifecycleState = .stopped
                    outcome = .stopped
                }

                self.connectionsLock.lock()
                self.activeConnections.removeAll()
                self.isShuttingDown = false
                self.connectionsLock.unlock()

                completion?(outcome)
                for pending in self.pendingStopCompletions {
                    pending(outcome)
                }
                self.pendingStopCompletions.removeAll()

                // listener failure の場合のみ通知（ownership 取得経路のみ）
                if case .listenerFailure(let error) = teardownReason {
                    self.onListenerFailure(error)
                }
            }
        }
    }

    // MARK: - Accept ループ

    private func acceptLoop(fd: Int32, generation capturedGeneration: UInt64) {
        var consecutiveErrors = 0

        acceptWhile: while true {
            let clientFd = socketOps.accept(fd, nil, nil)

            if clientFd >= 0 {
                consecutiveErrors = 0

                // FD_CLOEXEC
                if fcntl(clientFd, F_SETFD, FD_CLOEXEC) == -1 {
                    os_log(.error, "FD_CLOEXEC 設定失敗（client socket）: errno=%d", errno)
                }

                // generation チェック
                let generationMatch = stateQueue.sync { self.generation == capturedGeneration }
                if !generationMatch {
                    _ = socketOps.close(clientFd)
                    return
                }

                handleNewConnection(fd: clientFd, generation: capturedGeneration)
                continue acceptWhile
            }

            // accept エラー処理
            let acceptErrno = errno
            switch acceptErrno {
            case EINTR:
                continue acceptWhile
            case EBADF, EINVAL:
                let generationChanged = stateQueue.sync { self.generation != capturedGeneration }
                if generationChanged {
                    return // stop() による正常終了
                }
                os_log(.fault, "予期しない fd 破壊: errno=%d", acceptErrno)
                triggerListenerFailure(HookServerError.listenFailed(errno: acceptErrno))
                return
            case ECONNABORTED:
                os_log(.debug, "accept: ECONNABORTED（transient）")
                continue acceptWhile
            case EMFILE, ENFILE:
                os_log(.error, "accept: fd 枯渇 errno=%d", acceptErrno)
                sleeper(100_000)
                consecutiveErrors += 1
            default:
                os_log(.error, "accept エラー: errno=%d", acceptErrno)
                consecutiveErrors += 1
            }

            if consecutiveErrors >= 5 {
                os_log(.fault, "accept 連続5回失敗")
                triggerListenerFailure(HookServerError.listenFailed(errno: acceptErrno))
                return
            }
        }
    }

    /// accept ループから listener failure を通知する共通パス
    private func triggerListenerFailure(_ error: HookServerError) {
        DispatchQueue.main.async {
            if self.beginTeardown(reason: .listenerFailure(error)) {
                self.performTeardown(reason: .listenerFailure(error), completion: nil)
            }
        }
    }

    // MARK: - 接続処理

    private func handleNewConnection(fd clientFd: Int32, generation capturedGeneration: UInt64) {
        // step 1: lock 外で generation チェック（lock 順序: stateQueue → connectionsLock）
        let generationMatch = stateQueue.sync { self.generation == capturedGeneration }
        if !generationMatch {
            _ = socketOps.close(clientFd)
            return
        }

        // step 2b: テスト seam（generation check 通過後、connectionsLock 取得前）
        testHook_afterGenerationCheckBeforeRegister?(clientFd)

        // step 3: connectionsLock で登録
        connectionsLock.lock()
        if isShuttingDown {
            connectionsLock.unlock()
            _ = socketOps.close(clientFd)
            return
        }
        let connection = Connection(fd: clientFd, ops: socketOps)
        activeConnections.append(connection)
        connectionGroup.enter()
        connectionsLock.unlock()

        // 接続ごとの serial queue で read ループ
        let decoder = LineBufferedEventDecoder()
        let connectionQueue = DispatchQueue(label: "com.clabotch.socket.\(UUID().uuidString)")

        connectionQueue.async { [capturedGeneration] in
            defer {
                self.connectionGroup.leave()
            }

            let readBuf = UnsafeMutableRawBufferPointer.allocate(byteCount: 4096, alignment: 1)
            defer { readBuf.deallocate() }

            readLoop: while true {
                let bytesRead = self.socketOps.read(clientFd, readBuf.baseAddress!, readBuf.count)

                if bytesRead > 0 {
                    let chunk = Data(bytes: readBuf.baseAddress!, count: bytesRead)
                    let lines = decoder.append(chunk)
                    if !lines.isEmpty {
                        let generationOk = self.stateQueue.sync { self.generation == capturedGeneration }
                        guard generationOk else { break readLoop }

                        // [2] parse（connectionQueue 上、pure function）
                        var envelopes: [ClabotchEnvelope] = []
                        for line in lines {
                            if let envelope = EventParser.parse(line) {
                                envelopes.append(envelope)
                            } else {
                                os_log(.debug, "EventParser: 行を破棄（不正 JSON または必須フィールド欠損）")
                            }
                        }

                        // [3] dedup + callback（main thread）
                        if !envelopes.isEmpty {
                            DispatchQueue.main.async { [capturedGeneration] in
                                let generationOk = self.stateQueue.sync { self.generation == capturedGeneration }
                                guard generationOk else { return }
                                for envelope in envelopes {
                                    guard self.deduplicator.shouldAccept(envelope.eventID) else { continue }
                                    self.onEvent(envelope)
                                }
                            }
                        }
                    }
                    continue readLoop
                }

                // EOF
                if bytesRead == 0 { break readLoop }

                // read エラー
                let readErrno = errno
                if readErrno == EINTR { continue readLoop }

                // ECONNRESET / EBADF / ENOTCONN / その他 → ループ終了
                if readErrno != ECONNRESET {
                    let isExpected = (readErrno == EBADF || readErrno == ENOTCONN)
                        && self.stateQueue.sync { self.generation != capturedGeneration }
                    if !isExpected {
                        os_log(.error, "read エラー: errno=%d", readErrno)
                    }
                }
                break readLoop
            }

            // cleanup: closeOnce 先、connectionsLock 後（lock 順序: Connection.lock → connectionsLock）
            connection.closeOnce()
            self.connectionsLock.lock()
            self.activeConnections.removeAll { $0 === connection }
            self.connectionsLock.unlock()
        }
    }

    // MARK: - Socket ディレクトリ

    private func ensureSocketDir(retryCount: Int = 0) throws {
        var st = stat()
        if lstat(socketDir, &st) == 0 {
            // 既存
            guard (st.st_mode & S_IFMT) == S_IFDIR else {
                throw HookServerError.socketDirInvalid(reason: .notDirectory)
            }
            guard st.st_uid == getuid() else {
                throw HookServerError.socketDirInvalid(reason: .wrongOwner(uid: st.st_uid))
            }
            guard (st.st_mode & 0o777) == 0o700 else {
                throw HookServerError.socketDirInvalid(reason: .wrongPermissions(mode: st.st_mode & 0o777))
            }
        } else if errno == ENOENT {
            // 新規作成
            if mkdir(socketDir, 0o700) != 0 {
                let mkdirErrno = errno
                if mkdirErrno == EEXIST {
                    // race: 別インスタンスが作成 → 1回だけ再検証
                    guard retryCount < 1 else {
                        throw HookServerError.mkdirFailed(errno: mkdirErrno)
                    }
                    try ensureSocketDir(retryCount: retryCount + 1)
                    return
                }
                throw HookServerError.mkdirFailed(errno: mkdirErrno)
            }
        } else {
            throw HookServerError.statFailed(path: socketDir, errno: errno)
        }
    }

    // MARK: - Stale socket

    private func handleStaleSocket() throws {
        var st = stat()
        if lstat(socketPath, &st) != 0 {
            if errno == ENOENT {
                return // socket なし
            }
            throw HookServerError.statFailed(path: socketPath, errno: errno)
        }

        // socket 型確認
        guard (st.st_mode & S_IFMT) == S_IFSOCK else {
            // 通常ファイルや symlink → unlink しない
            throw HookServerError.socketFileInvalid(reason: .notSocket)
        }

        // owner 確認
        guard st.st_uid == getuid() else {
            throw HookServerError.socketFileInvalid(reason: .wrongOwner(uid: st.st_uid))
        }

        // connect() probe
        let probeFd = socketOps.socket(AF_UNIX, SOCK_STREAM, 0)
        guard probeFd >= 0 else {
            throw HookServerError.probeSocketCreationFailed(errno: errno)
        }
        defer { _ = socketOps.close(probeFd) }

        var probeAddr = sockaddr_un()
        probeAddr.sun_family = sa_family_t(AF_UNIX)
        probeAddr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &probeAddr.sun_path) { buf in
            socketPath.withCString { src in
                _ = memcpy(buf.baseAddress!, src, min(strlen(src) + 1, buf.count))
            }
        }

        let connectResult = withUnsafePointer(to: &probeAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                socketOps.connect(probeFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if connectResult == 0 {
            throw HookServerError.alreadyRunning
        }

        let connectErrno = errno
        switch connectErrno {
        case ECONNREFUSED:
            // stale socket → unlink
            if unlink(socketPath) != 0 && errno != ENOENT {
                throw HookServerError.unlinkFailed(path: socketPath, errno: errno)
            }
        case ENOENT:
            // socket 消えた → 続行
            break
        default:
            throw HookServerError.socketProbeError(errno: connectErrno)
        }
    }

    /// probe: socket が live かどうか。bind(EADDRINUSE) 後の再確認用。
    private func probeSocketLive() -> Bool {
        let probeFd = socketOps.socket(AF_UNIX, SOCK_STREAM, 0)
        guard probeFd >= 0 else { return false }
        defer { _ = socketOps.close(probeFd) }

        var probeAddr = sockaddr_un()
        probeAddr.sun_family = sa_family_t(AF_UNIX)
        probeAddr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &probeAddr.sun_path) { buf in
            socketPath.withCString { src in
                _ = memcpy(buf.baseAddress!, src, min(strlen(src) + 1, buf.count))
            }
        }

        return withUnsafePointer(to: &probeAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                socketOps.connect(probeFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }
}
