import AppKit

/// §11.7 オンボーディング UI — 初回起動時の AX 権限リクエストダイアログ。
/// 「後で」= notGranted のまま続行、「許可する」= requestPermission() で macOS ダイアログを表示。
final class OnboardingWindowController {

    enum Result: Equatable {
        case allowClicked   // 「許可する」→ System Settings へ誘導
        case laterClicked   // 「後で」→ frame02 固定で続行
    }

    /// 初回起動判定キー
    private static let didShowOnboardingKey = "didShowOnboarding"

    /// 初回起動ダイアログを表示すべきかどうか
    static var shouldShow: Bool {
        !UserDefaults.standard.bool(forKey: didShowOnboardingKey)
    }

    /// オンボーディングダイアログを表示する。
    /// - Parameter completion: ユーザーの選択結果を返す。
    /// テスト seam: アラートの表示と応答取得を差し替え可能にする。
    /// production ではデフォルトの NSAlert.runModal() を使用。
    static var alertPresenter: () -> NSApplication.ModalResponse = {
        let alert = NSAlert()
        alert.messageText = L10n.onboardingTitle
        alert.informativeText = L10n.onboardingMessage
        alert.alertStyle = .informational
        // LSUIElement アプリはアイコンが自動設定されないため明示指定
        alert.icon = NSApp.applicationIconImage

        // ボタン追加（先に追加したものが右側 = デフォルト）
        alert.addButton(withTitle: L10n.onboardingAllow)
        alert.addButton(withTitle: L10n.commonLater)

        return alert.runModal()
    }

    /// オンボーディングダイアログを表示する。
    /// フラグはダイアログ完了後に書き込む（クラッシュ時に再表示可能にするため）。
    /// - Parameter completion: ユーザーの選択結果を返す。
    static func show(completion: @escaping (Result) -> Void) {
        let response = alertPresenter()

        // ダイアログ完了後にフラグを立てる
        UserDefaults.standard.set(true, forKey: didShowOnboardingKey)

        if response == .alertFirstButtonReturn {
            completion(.allowClicked)
        } else {
            completion(.laterClicked)
        }
    }

    /// テスト用: didShowOnboarding フラグをリセットする
    static func resetForTesting() {
        UserDefaults.standard.removeObject(forKey: didShowOnboardingKey)
    }
}
