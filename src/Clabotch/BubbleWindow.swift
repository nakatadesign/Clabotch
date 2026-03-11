import AppKit

/// 吹き出しウィンドウ。メニューバーの下に表示し、自動消去する。
/// v11 §5, §6 準拠。
final class BubbleWindow: BubblePresenting {

    // MARK: - DI seam（テスト用）

    /// ウィンドウ生成ファクトリ。テストでは nil を返すスタブを注入してヘッドレス実行を可能にする。
    var windowFactory: (_ anchor: CGPoint, _ text: String) -> NSWindow? = { anchor, text in
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .labelColor
        label.backgroundColor = .clear
        label.sizeToFit()

        let padding: CGFloat = 8
        let contentSize = CGSize(
            width: label.frame.width + padding * 2,
            height: label.frame.height + padding * 2
        )
        let windowOrigin = CGPoint(
            x: anchor.x - contentSize.width / 2,
            y: anchor.y - contentSize.height - 4
        )

        let w = NSWindow(
            contentRect: NSRect(origin: windowOrigin, size: contentSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.isOpaque = false
        w.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95)
        w.level = .statusBar
        w.hasShadow = true
        w.ignoresMouseEvents = true
        label.frame.origin = CGPoint(x: padding, y: padding)
        w.contentView?.addSubview(label)
        w.orderFront(nil)
        return w
    }

    /// タイマースケジューラ。テストではクロージャを捕捉して手動発火できる。
    var timerScheduler: (_ interval: TimeInterval, _ handler: @escaping () -> Void) -> Timer = { interval, handler in
        Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in handler() }
    }

    // MARK: - 状態

    private var window: NSWindow?
    private(set) var dismissTimer: Timer?

    /// 現在表示中かどうか
    private(set) var isShowing: Bool = false

    /// 最後に show() で渡されたテキスト
    private(set) var lastText: String?

    /// 吹き出しを表示する。既存の吹き出しがあれば差し替える。
    func show(text: String, anchor: CGPoint, duration: TimeInterval = 3.0) {
        dispatchPrecondition(condition: .onQueue(.main))
        dismiss()

        lastText = text
        isShowing = true
        window = windowFactory(anchor, text)

        dismissTimer?.invalidate()
        dismissTimer = timerScheduler(duration) { [weak self] in
            self?.dismiss()
        }
    }

    /// 吹き出しを即座に消す。
    func dismiss() {
        dispatchPrecondition(condition: .onQueue(.main))
        dismissTimer?.invalidate()
        dismissTimer = nil
        window?.close()
        window = nil
        isShowing = false
    }
}
