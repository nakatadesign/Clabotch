import AppKit

/// 吹き出しウィンドウ。メニューバーの下に表示し、自動消去する。
/// v11 §5, §6 準拠。
final class BubbleWindow: BubblePresenting {

    private(set) var window: NSWindow?
    private(set) var dismissTimer: Timer?

    /// 現在表示中かどうか（テスト用）
    var isShowing: Bool { window != nil }

    /// 最後に show() で渡されたテキスト（テスト用）
    private(set) var lastText: String?

    /// 吹き出しを表示する。既存の吹き出しがあれば差し替える。
    /// - Parameters:
    ///   - text: 表示テキスト
    ///   - anchor: メニューバーアイコンの画面座標
    ///   - duration: 表示秒数（デフォルト 3.0）
    func show(text: String, anchor: CGPoint, duration: TimeInterval = 3.0) {
        dispatchPrecondition(condition: .onQueue(.main))
        dismiss()

        lastText = text

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

        // メニューバー直下に配置
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
        w.ignoresMouseEvents = true  // 通知専用: 背後 UI をブロックしない

        label.frame.origin = CGPoint(x: padding, y: padding)
        w.contentView?.addSubview(label)

        w.orderFront(nil)
        window = w

        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
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
    }
}
