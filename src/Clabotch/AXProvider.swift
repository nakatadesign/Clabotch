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
        return (CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2), nil)
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
