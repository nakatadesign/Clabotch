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

        // GazeController → ClabotchEyeView
        gazeController.onGazeFrameChanged = { [weak self] frame in
            self?.eyeView?.setGazeFrame(frame)
        }

        // BlinkController → ClabotchEyeView
        blinkController.onBlink = { [weak self] in
            self?.eyeView?.triggerBlink()
        }

        // StateMachine コールバック（Coordinator 役）
        stateMachine.onPhaseChanged = { [weak self] phase in
            guard let self else { return }
            os_log(.info, "フェーズ変更: %{public}@", String(describing: phase))

            // GazeController: phase → override 変換
            let override = Self.gazeOverride(for: phase)
            self.gazeController.setOverride(override)

            // BlinkController: phase → enabled 変換
            let blinkEnabled = Self.isBlinkEnabled(for: phase)
            self.blinkController.setBlinking(enabled: blinkEnabled)

            // ClabotchEyeView: phase → 外見変更
            self.eyeView?.setPhaseAppearance(phase: phase)

            // BubbleWindow: phase → 吹き出し表示
            if let text = Self.bubbleText(for: phase) {
                if let anchor = self.statusItemAnchor() {
                    self.bubbleWindow.show(text: text, anchor: anchor)
                }
            } else {
                self.bubbleWindow.dismiss()
            }
        }

        stateMachine.onEphemeralDone = { [weak self] elapsedMs in
            guard let self else { return }
            let text = Self.formatElapsedTime(elapsedMs)
            let display = "別セッション完了 (\(text))"
            if let anchor = self.statusItemAnchor() {
                self.ephemeralBubbleWindow.show(text: display, anchor: anchor, duration: 2.0)
            }
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

        do {
            try hookServer?.start()
            os_log(.info, "HookServer started")
            stateMachine.start()          // ① 初期フェーズ emit → setOverride / setBlinking
            gazeController.startPolling() // ② polling 開始
        } catch let error as HookServerError where error == .alreadyRunning {
            os_log(.error, "既に別インスタンスが起動中")
            NSApplication.shared.terminate(nil)
        } catch {
            os_log(.error, "HookServer failed to start: %{public}@", error.localizedDescription)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        bubbleWindow.dismiss()
        ephemeralBubbleWindow.dismiss()
        blinkController.setBlinking(enabled: false)
        gazeController.stopPolling()
        hookServer?.terminateSync()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Phase → Override 変換（v11 §11.5 対応表準拠）

    static func gazeOverride(for phase: MascotPhase) -> GazeOverride {
        switch phase {
        case .idle:     return .fixed(frame: .f02_rightDown, reason: .mascotStateOverride)
        case .thinking: return .none
        case .working:  return .none
        case .done:     return .fixed(frame: .f02_rightDown, reason: .mascotStateOverride)
        case .error:    return .fixed(frame: .f01_center, reason: .mascotStateOverride)
        case .sleeping: return .fixed(frame: .f01_center, reason: .mascotStateOverride)
        }
    }

    // MARK: - Phase → Blink 変換（v11 §6 準拠）

    static func isBlinkEnabled(for phase: MascotPhase) -> Bool {
        switch phase {
        case .idle, .thinking, .working, .done: return true
        case .error, .sleeping:                 return false
        }
    }

    // MARK: - Phase → 吹き出し文言（v11 §6 準拠）

    static func bubbleText(for phase: MascotPhase) -> String? {
        switch phase {
        case .thinking:
            return "考えてます..."
        case .working(let toolName):
            return "\(toolName) 実行中..."
        case .done(let elapsedMs):
            if elapsedMs > 0 {
                return "完了！(\(formatElapsedTime(elapsedMs)))"
            } else {
                return "完了！"
            }
        case .error:
            return "エラーが出ました…"  // v11 §6 固定文言。詳細 error_message は v1.0+ (§13.6)
        case .idle, .sleeping:
            return nil
        }
    }

    // MARK: - ヘルパー

    static func formatElapsedTime(_ ms: Int) -> String {
        let totalSeconds = ms / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes > 0 {
            return "\(minutes)分\(seconds)秒"
        } else {
            return "\(seconds)秒"
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
