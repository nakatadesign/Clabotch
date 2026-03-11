import Foundation
@testable import Clabotch

/// テスト用 MockSocketOps。各 syscall の戻り値・errno を注入可能。
final class MockSocketOps: SocketOps {
    // クロージャで個別の振る舞いを注入
    var onSocket: ((Int32, Int32, Int32) -> Int32)?
    var onBind: ((Int32, UnsafePointer<sockaddr>, socklen_t) -> Int32)?
    var onListen: ((Int32, Int32) -> Int32)?
    var onAccept: ((Int32, UnsafeMutablePointer<sockaddr>?, UnsafeMutablePointer<socklen_t>?) -> Int32)?
    var onRead: ((Int32, UnsafeMutableRawPointer, Int) -> Int)?
    var onClose: ((Int32) -> Int32)?
    var onConnect: ((Int32, UnsafePointer<sockaddr>, socklen_t) -> Int32)?
    var onShutdown: ((Int32, Int32) -> Int32)?

    // 呼び出し記録
    var closedFds: [Int32] = []
    var shutdownFds: [Int32] = []

    // デフォルト fd カウンタ
    private var nextFd: Int32 = 100

    func socket(_ domain: Int32, _ type: Int32, _ proto: Int32) -> Int32 {
        if let handler = onSocket { return handler(domain, type, proto) }
        let fd = nextFd
        nextFd += 1
        return fd
    }

    func bind(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 {
        if let handler = onBind { return handler(fd, addr, len) }
        return 0
    }

    func listen(_ fd: Int32, _ backlog: Int32) -> Int32 {
        if let handler = onListen { return handler(fd, backlog) }
        return 0
    }

    func accept(_ fd: Int32, _ addr: UnsafeMutablePointer<sockaddr>?, _ len: UnsafeMutablePointer<socklen_t>?) -> Int32 {
        if let handler = onAccept { return handler(fd, addr, len) }
        // デフォルト: EBADF（stop で close された想定）
        errno = EBADF
        return -1
    }

    func read(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ nbyte: Int) -> Int {
        if let handler = onRead { return handler(fd, buf, nbyte) }
        return 0 // EOF
    }

    func close(_ fd: Int32) -> Int32 {
        closedFds.append(fd)
        if let handler = onClose { return handler(fd) }
        return 0
    }

    func connect(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 {
        if let handler = onConnect { return handler(fd, addr, len) }
        errno = ECONNREFUSED
        return -1
    }

    func shutdown(_ fd: Int32, _ how: Int32) -> Int32 {
        shutdownFds.append(fd)
        if let handler = onShutdown { return handler(fd, how) }
        return 0
    }
}
