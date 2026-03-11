import AppKit
import os.log

/// メニューバー常駐アプリの AppDelegate。
/// HookServer の起動・停止と NSStatusItem の管理を担当する。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var hookServer: HookServer?
    private let deduplicator = EventDeduplicator()
    private let stateMachine = StateMachine()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // メニューバーに「C」を表示
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "C"

        // メニュー構築
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit Clabotch", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem?.menu = menu

        // StateMachine コールバック設定
        stateMachine.onPhaseChanged = { phase in
            os_log(.info, "フェーズ変更: %{public}@", String(describing: phase))
        }
        stateMachine.onEphemeralDone = { elapsedMs in
            os_log(.info, "ephemeral done: %d ms", elapsedMs)
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
            stateMachine.start()
        } catch let error as HookServerError where error == .alreadyRunning {
            os_log(.error, "既に別インスタンスが起動中")
            NSApplication.shared.terminate(nil)
        } catch {
            os_log(.error, "HookServer failed to start: %{public}@", error.localizedDescription)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hookServer?.terminateSync()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
