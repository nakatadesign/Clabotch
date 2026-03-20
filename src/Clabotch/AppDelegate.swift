import AppKit
import os.log

/// メニューバー常駐アプリの AppDelegate。
/// HookServer の起動・停止と NSStatusItem の管理を担当する。
/// Coordinator 役: StateMachine.onPhaseChanged → GazeController / BlinkController / ClabotchEyeView / BubbleWindow の結線。
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
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

        // ClabotchEyeView を button.image ベースで描画する（patch_018: macOS メニューバー dim 対応）
        if let button = statusItem?.button {
            button.title = ""
            eyeView = Self.setupEyeView(on: button)
        }

        // メニュー構築
        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "設定...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit Clabotch", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        menu.delegate = self
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

        // AX 権限変化 → 設定画面のステータス更新
        binder?.onAccessibilityStatusChanged = { [weak self] _ in
            self?.settingsWindowController?.refreshAccessibilityStatus()
        }

        // 設定変更 → StateMachine / EyeView へ伝播
        settingsStore.onChange = { [weak self] in
            guard let self else { return }
            self.stateMachine.updateSleepThreshold(self.settingsStore.sleepTimeoutSeconds)
            self.applyAnimationSpeed()
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
        applyAnimationSpeed() // 保存済みアニメーション速度を反映
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

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        eyeView?.showMenuFace()
        // 瞬き程度の速さで元に戻す（120ms）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.eyeView?.hideMenuFace()
        }
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

    // MARK: - EyeView セットアップ（patch_018）

    /// ClabotchEyeView を button.image ベースで初期化する。
    /// 描画結果を button.image に反映し、macOS の自動 dim に委ねる。
    /// subview は isHidden=true で残す（テスト互換性。表示の source of truth は button.image）。
    ///
    /// 初期化順（変更禁止）:
    ///   ① statusBarButton 設定 → ② addSubview → ③ isHidden=true → ④ scheduleUpdate
    /// テストから直接呼べるよう static メソッドとして公開。
    @discardableResult
    static func setupEyeView(on button: NSStatusBarButton) -> ClabotchEyeView {
        let view = ClabotchEyeView(frame: button.bounds)
        view.autoresizingMask = [.width, .height]
        view.statusBarButton = button      // ① image 更新先を先に設定
        button.addSubview(view)            // ② subview 追加（viewDidMoveToWindow が発火）
        view.isHidden = true               // ③ 描画は button.image で行う
        view.scheduleUpdate()              // ④ 初回 image を確定的に生成
        return view
    }

    private func statusItemAnchor() -> CGPoint? {
        guard let button = statusItem?.button,
              let window = button.window else { return nil }
        let frameInWindow = button.convert(button.bounds, to: nil)
        let frameOnScreen = window.convertToScreen(frameInWindow)
        return CGPoint(x: frameOnScreen.midX, y: frameOnScreen.minY)
    }

    // MARK: - アニメーション速度

    /// 保存済みのアニメーション速度倍率を EyeView に反映する。
    /// 現在 .thinking / .responding 表示中なら、新しい速度でアニメーションを即時再起動する。
    /// .done / .error は再発火の副作用があるため、次回 phase 開始時から反映される。
    private func applyAnimationSpeed() {
        guard let eyeView else { return }
        let m = settingsStore.animationSpeedMultiplier
        eyeView.thinkingAnimInterval = ClabotchEyeView.defaultThinkingAnimInterval * m
        eyeView.respondingAnimInterval = ClabotchEyeView.defaultRespondingAnimInterval * m
        eyeView.doneAnimInterval = ClabotchEyeView.defaultDoneAnimInterval * m
        eyeView.jumpInterval = ClabotchEyeView.defaultJumpInterval * m
        eyeView.errorShakeInterval = ClabotchEyeView.defaultErrorShakeInterval * m

        // 現在 phase が .thinking / .responding なら即時再適用
        // .done / .error は再発火（jump/rainbow/shake）の副作用があるため即時再適用しない
        let phase = stateMachine.displayPhase
        switch phase {
        case .thinking, .responding:
            eyeView.setPhaseAppearance(phase: phase)
        default:
            break
        }
    }
}
