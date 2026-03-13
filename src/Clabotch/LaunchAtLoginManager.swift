import Foundation
import ServiceManagement
import os.log

/// ログイン時自動起動の状態取得・変更を抽象化するプロトコル。
/// テストではモック実装を注入する。
protocol LaunchAtLoginProviding: AnyObject {
    /// 現在ログイン時自動起動が有効か
    var isEnabled: Bool { get }
    /// ログイン時自動起動を有効/無効にする
    func setEnabled(_ enabled: Bool) throws
}

/// SMAppService を使ったログイン時自動起動管理。macOS 13+ 対応。
final class LaunchAtLoginManager: LaunchAtLoginProviding {

    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
            os_log(.info, "LaunchAgent 登録成功")
        } else {
            try SMAppService.mainApp.unregister()
            os_log(.info, "LaunchAgent 解除成功")
        }
    }
}
