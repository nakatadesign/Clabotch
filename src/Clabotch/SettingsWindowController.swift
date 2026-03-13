import AppKit
import os.log

/// 設定パネルのウィンドウコントローラー。
/// メニューバーの「設定...」から開かれる。NSStackView ベースのレイアウト。
final class SettingsWindowController: NSObject {

    // MARK: - DI seam（テスト用）

    /// ウィンドウ生成ファクトリ。テストでは nil を返してヘッドレス実行する。
    var windowFactory: (_ contentView: NSView) -> NSWindow? = { contentView in
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Clabotch 設定"
        window.contentView = contentView
        window.center()
        window.isReleasedWhenClosed = false
        return window
    }

    // MARK: - 状態

    private var window: NSWindow?
    private let settingsStore: SettingsStore
    private let launchAtLogin: LaunchAtLoginProviding

    /// ポップアップボタン（テスト検証用に公開）
    private(set) var sleepPopup: NSPopUpButton?
    /// チェックボックス（テスト検証用に公開）
    private(set) var launchAtLoginCheckbox: NSButton?

    init(settingsStore: SettingsStore, launchAtLogin: LaunchAtLoginProviding = LaunchAtLoginManager()) {
        self.settingsStore = settingsStore
        self.launchAtLogin = launchAtLogin
        super.init()
    }

    // MARK: - 表示

    /// 設定ウィンドウを表示する。既に開いている場合は前面に移動する。
    func showWindow() {
        dispatchPrecondition(condition: .onQueue(.main))

        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = buildContentView()
        window = windowFactory(contentView)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 設定ウィンドウを閉じる。
    func close() {
        window?.close()
        window = nil
    }

    /// ウィンドウが表示中か
    var isVisible: Bool {
        window?.isVisible ?? false
    }

    // MARK: - UI 構築

    private func buildContentView() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        // ログイン時自動起動行
        let launchRow = buildLaunchAtLoginRow()
        stack.addArrangedSubview(launchRow)

        // スリープタイムアウト行
        let sleepRow = buildSleepTimeoutRow()
        stack.addArrangedSubview(sleepRow)

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])

        return container
    }

    private func buildSleepTimeoutRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8

        let label = NSTextField(labelWithString: "スリープまで:")
        label.font = .systemFont(ofSize: 13)

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.font = .systemFont(ofSize: 13)

        let currentMinutes = settingsStore.sleepTimeoutMinutes
        for option in SettingsStore.sleepTimeoutOptions {
            popup.addItem(withTitle: option.label)
            popup.lastItem?.tag = option.minutes
            if option.minutes == currentMinutes {
                popup.selectItem(withTitle: option.label)
            }
        }

        popup.target = self
        popup.action = #selector(sleepTimeoutChanged(_:))

        row.addArrangedSubview(label)
        row.addArrangedSubview(popup)

        sleepPopup = popup
        return row
    }

    @objc private func sleepTimeoutChanged(_ sender: NSPopUpButton) {
        guard let selectedItem = sender.selectedItem else { return }
        settingsStore.sleepTimeoutMinutes = selectedItem.tag
    }

    // MARK: - ログイン時自動起動

    private func buildLaunchAtLoginRow() -> NSView {
        let checkbox = NSButton(checkboxWithTitle: "ログイン時に起動", target: self, action: #selector(launchAtLoginChanged(_:)))
        checkbox.font = .systemFont(ofSize: 13)
        checkbox.state = launchAtLogin.isEnabled ? .on : .off
        launchAtLoginCheckbox = checkbox
        return checkbox
    }

    @objc private func launchAtLoginChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        do {
            try launchAtLogin.setEnabled(enabled)
        } catch {
            // 失敗時はチェックを元に戻す
            sender.state = launchAtLogin.isEnabled ? .on : .off
            os_log(.error, "LaunchAgent 変更失敗: %{public}@", error.localizedDescription)
        }
    }
}
