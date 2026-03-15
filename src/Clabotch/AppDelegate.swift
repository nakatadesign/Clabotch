import AppKit
import os.log

/// メニューバー常駐アプリの AppDelegate。
/// HookServer の起動・停止と NSStatusItem の管理を担当する。
/// Coordinator 役: StateMachine.onPhaseChanged → GazeController / BlinkController / ClabotchEyeView / BubbleWindow の結線。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var hookServer: HookServer?
    private let deduplicator = EventDeduplicator()
    private let stateMachine = StateMachine()
    private let gazeController = GazeController()
    private let blinkController = BlinkController()
    private var eyeView: ClabotchEyeView?
    private let bubbleWindow = BubbleWindow()
    private let ephemeralBubbleWindow = BubbleWindow()
    private var binder: CoordinatorBinder?
    private let settingsStore = SettingsStore()
    private let launchAtLoginManager = LaunchAtLoginManager()
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // メニューバー設定（22px 固定幅）
        statusItem = NSStatusBar.system.statusItem(withLength: 22)

        // ClabotchEyeView をステータスバーボタンに埋め込む
        if let button = statusItem?.button {
            button.title = ""
            let view = ClabotchEyeView(frame: button.bounds)
            view.autoresizingMask = [.width, .height]
            button.addSubview(view)
            eyeView = view
        }

        // メニュー構築
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "設定...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Clabotch", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem?.menu = menu

        // GazeController のステータスアイテム中心座標プロバイダ設定
        gazeController.statusItemCenterProvider = { [weak self] in
            guard let button = self?.statusItem?.button,
                  let window = button.window else { return nil }
            let frameInWindow = button.convert(button.bounds, to: nil)
            let frameOnScreen = window.convertToScreen(frameInWindow)
            return CGPoint(x: frameOnScreen.midX, y: frameOnScreen.midY)
        }

        // Coordinator 結線（CoordinatorBinder に委譲）
        binder = CoordinatorBinder(
            stateMachine: stateMachine,
            gazeController: gazeController,
            blinkController: blinkController,
            eyeView: eyeView,
            activeBubble: bubbleWindow,
            ephemeralBubble: ephemeralBubbleWindow,
            anchorProvider: { [weak self] in self?.statusItemAnchor() }
        )
        binder?.bind()

        // 設定変更 → StateMachine へ伝播
        settingsStore.onChange = { [weak self] in
            guard let self else { return }
            self.stateMachine.updateSleepThreshold(self.settingsStore.sleepTimeoutSeconds)
        }

        // HookServer 初期化・起動
        let tmpDir = NSTemporaryDirectory().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let socketDir = "/" + tmpDir + "/clabotch"

        hookServer = HookServer(
            socketDir: socketDir,
            deduplicator: deduplicator,
            onEvent: { [weak self] envelope in
                self?.stateMachine.handle(event: envelope.event)
            },
            onListenerFailure: { error in
                os_log(.fault, "HookServer listener が停止: %{public}@", String(describing: error))
            }
        )

        // HookServer 初期化・起動（UI 初期化とは独立）
        do {
            try hookServer?.start()
            os_log(.info, "HookServer started")

            // HookServer 起動成功 = 新プロセス → SESSION_REGISTRY をクリア
            // hooks 側が「session_start 送信済み」と誤認するのを防ぐ
            let sessionRegistry = "/" + tmpDir + "/clabotch_sessions"
            try? FileManager.default.removeItem(atPath: sessionRegistry)
        } catch let error as HookServerError where error == .alreadyRunning {
            os_log(.error, "既に別インスタンスが起動中")
            NSApplication.shared.terminate(nil)
            return  // terminate 後の処理を明示的に停止
        } catch {
            os_log(.fault, "HookServer failed to start: %{public}@", error.localizedDescription)
            // HookServer なしで続行（フック未受信だがマスコットとして最低限動作）
        }

        // UI 初期化（HookServer の成否に依存しない）
        stateMachine.updateSleepThreshold(settingsStore.sleepTimeoutSeconds) // 保存済み設定を反映
        stateMachine.start()          // ① 初期フェーズ emit → setOverride / setBlinking
        gazeController.startPolling() // ② polling 開始

        // §11.7 オンボーディング: 初回起動時のみ AX 権限ダイアログを表示
        if OnboardingWindowController.shouldShow {
            OnboardingWindowController.show { [weak self] result in
                guard let self else { return }
                switch result {
                case .allowClicked:
                    self.gazeController.requestPermission()
                case .laterClicked:
                    break  // notGranted のまま続行（視線固定）
                }
            }
        } else if !AXIsProcessTrusted() {
            // 再起動・リビルド等で AX 権限がリセットされた場合、システム設定を開くよう案内
            showAccessibilityAlert()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        bubbleWindow.dismiss()
        ephemeralBubbleWindow.dismiss()
        blinkController.setBlinking(enabled: false)
        gazeController.stopPolling()
        hookServer?.terminateSync()
    }

    @objc private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(settingsStore: settingsStore, launchAtLogin: launchAtLoginManager)
        }
        settingsWindowController?.showWindow()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - AX 権限復旧案内

    /// テスト seam: アラートの表示と応答取得を差し替え可能にする。
    static var accessibilityAlertPresenter: () -> NSApplication.ModalResponse = {
        let alert = NSAlert()
        alert.messageText = "アクセシビリティの許可が必要です"
        alert.informativeText = """
            視線追跡にはアクセシビリティの許可が必要です。

            「システム設定を開く」を押して、一覧に Clabotch を追加し\
            チェックを入れてください。
            既にチェックが入っている場合は、一度外してから\
            再度入れ直すと改善する場合があります。
            """
        alert.alertStyle = .warning
        // LSUIElement アプリはアイコンが自動設定されないため明示指定
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: "システム設定を開く")
        alert.addButton(withTitle: "後で")
        return alert.runModal()
    }

    private func showAccessibilityAlert() {
        let response = Self.accessibilityAlertPresenter()
        if response == .alertFirstButtonReturn {
            // アクセシビリティ設定画面を直接開く
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        }
    }

    private func statusItemAnchor() -> CGPoint? {
        guard let button = statusItem?.button,
              let window = button.window else { return nil }
        let frameInWindow = button.convert(button.bounds, to: nil)
        let frameOnScreen = window.convertToScreen(frameInWindow)
        return CGPoint(x: frameOnScreen.midX, y: frameOnScreen.minY)
    }
}
