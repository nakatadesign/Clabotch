import Darwin

/// POSIX syscall の薄いラッパー protocol。テスト時に MockSocketOps を注入可能。
protocol SocketOps {
    func socket(_ domain: Int32, _ type: Int32, _ proto: Int32) -> Int32
    func bind(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32
    func listen(_ fd: Int32, _ backlog: Int32) -> Int32
    func accept(_ fd: Int32, _ addr: UnsafeMutablePointer<sockaddr>?, _ len: UnsafeMutablePointer<socklen_t>?) -> Int32
    func read(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ nbyte: Int) -> Int
    func close(_ fd: Int32) -> Int32
    func connect(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32
    func shutdown(_ fd: Int32, _ how: Int32) -> Int32
}

/// 本番用。POSIX syscall を直接呼ぶ。zero-cost struct。
struct RealSocketOps: SocketOps {
    func socket(_ domain: Int32, _ type: Int32, _ proto: Int32) -> Int32 {
        Darwin.socket(domain, type, proto)
    }
    func bind(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 {
        Darwin.bind(fd, addr, len)
    }
    func listen(_ fd: Int32, _ backlog: Int32) -> Int32 {
        Darwin.listen(fd, backlog)
    }
    func accept(_ fd: Int32, _ addr: UnsafeMutablePointer<sockaddr>?, _ len: UnsafeMutablePointer<socklen_t>?) -> Int32 {
        Darwin.accept(fd, addr, len)
    }
    func read(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ nbyte: Int) -> Int {
        Darwin.read(fd, buf, nbyte)
    }
    func close(_ fd: Int32) -> Int32 {
        Darwin.close(fd)
    }
    func connect(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 {
        Darwin.connect(fd, addr, len)
    }
    func shutdown(_ fd: Int32, _ how: Int32) -> Int32 {
        Darwin.shutdown(fd, how)
    }
}
