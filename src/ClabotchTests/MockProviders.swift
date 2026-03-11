@testable import Clabotch
import Foundation

/// AXProvider のテスト用モック。
final class MockAXProvider: AXProvider {
    var isTrusted: Bool = false
    var requestTrustCalled: Bool = false
    var requestTrustResult: Bool = false
    var terminalCenter: CGPoint? = nil
    var terminalFailReason: FixedGazeReason? = nil

    func isProcessTrusted() -> Bool {
        isTrusted
    }

    @discardableResult
    func requestTrust(prompt: Bool) -> Bool {
        requestTrustCalled = true
        return requestTrustResult
    }

    func findTerminalCenter(pid: pid_t) -> (CGPoint?, FixedGazeReason?) {
        (terminalCenter, terminalFailReason)
    }
}

/// WorkspaceProvider のテスト用モック。
final class MockWorkspaceProvider: WorkspaceProvider {
    var bundleIdentifier: String? = nil
    var pid: pid_t? = nil

    func frontmostBundleIdentifier() -> String? {
        bundleIdentifier
    }

    func frontmostPID() -> pid_t? {
        pid
    }
}
