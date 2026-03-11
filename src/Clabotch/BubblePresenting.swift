import Foundation

/// 吹き出し表示のプロトコル。
/// BubbleWindow（プロダクション）と BubbleSpy（テスト）が準拠する。
protocol BubblePresenting: AnyObject {
    var isShowing: Bool { get }
    func show(text: String, anchor: CGPoint, duration: TimeInterval)
    func dismiss()
}

extension BubblePresenting {
    /// デフォルト duration 3.0 秒
    func show(text: String, anchor: CGPoint) {
        show(text: text, anchor: anchor, duration: 3.0)
    }
}
