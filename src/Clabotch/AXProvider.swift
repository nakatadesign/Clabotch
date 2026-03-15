import AppKit

/// AX API の抽象化。テスト時に MockAXProvider を注入する。
protocol AXProvider {
    /// AXIsProcessTrusted() の抽象化
    func isProcessTrusted() -> Bool

    /// AXIsProcessTrustedWithOptions() の抽象化
    @discardableResult
    func requestTrust(prompt: Bool) -> Bool

    /// ターミナルウィンドウの中心座標を取得する。
    /// 成功: (CGPoint, nil)  失敗: (nil, FixedGazeReason)
    func findTerminalCenter(pid: pid_t) -> (CGPoint?, FixedGazeReason?)
}

/// NSWorkspace の抽象化。テスト時に MockWorkspaceProvider を注入する。
protocol WorkspaceProvider {
    /// フロントアプリの bundleIdentifier を返す。nil ならアプリ未検出。
    func frontmostBundleIdentifier() -> String?

    /// フロントアプリの PID を返す。nil ならアプリ未検出。
    func frontmostPID() -> pid_t?
}

// MARK: - 本番実装

struct RealAXProvider: AXProvider {
    func isProcessTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    func requestTrust(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func findTerminalCenter(pid: pid_t) -> (CGPoint?, FixedGazeReason?) {
        let axApp = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
            let windows = ref as? [AXUIElement], !windows.isEmpty
        else { return (nil, .terminalMinimized) }

        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(windows[0], kAXPositionAttribute as CFString, &posRef) == .success,
            AXUIElementCopyAttributeValue(windows[0], kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return (nil, .terminalInOtherSpace) }

        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)

        // AX 座標系（Y=0 が画面上端、下向き正）→ Cocoa 座標系（Y=0 が画面下端、上向き正）に変換
        // マルチモニタ: primary screen (screens[0]) の高さが座標変換の基準
        let screenHeight = NSScreen.screens.first?.frame.height ?? 1440
        let centerX = pos.x + size.width / 2
        let centerY = screenHeight - (pos.y + size.height / 2)
        return (CGPoint(x: centerX, y: centerY), nil)
    }
}

struct RealWorkspaceProvider: WorkspaceProvider {
    func frontmostBundleIdentifier() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    func frontmostPID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
}

/// NSEvent.addGlobalMonitorForEvents を使った本番実装。
final class RealGlobalEventMonitor: GlobalEventMonitorProviding {
    private var monitor: Any?

    func startMonitoring(handler: @escaping () -> Void) {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in
            handler()
        }
    }

    func stopMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    deinit {
        stopMonitoring()
    }
}
