import XCTest
@testable import Clabotch

/// BubblePresenting 準拠の test double。
/// headless テスト環境で NSWindow 生成を回避し、show/dismiss の呼び出しを記録する。
final class BubbleSpy: BubblePresenting {
    struct ShowCall {
        let text: String
        let anchor: CGPoint
        let duration: TimeInterval
    }

    private(set) var showCalls: [ShowCall] = []
    private(set) var explicitDismissCount: Int = 0
    private(set) var isShowing: Bool = false
    private(set) var lastText: String?

    func show(text: String, anchor: CGPoint, duration: TimeInterval = 3.0) {
        dispatchPrecondition(condition: .onQueue(.main))
        // 実物 BubbleWindow 準拠: show() のたびに先に dismiss() する
        if isShowing {
            dismiss()
        }
        isShowing = true
        lastText = text
        showCalls.append(ShowCall(text: text, anchor: anchor, duration: duration))
    }

    func dismiss() {
        dispatchPrecondition(condition: .onQueue(.main))
        explicitDismissCount += 1
        isShowing = false
        lastText = nil
    }

    func reset() {
        showCalls = []
        explicitDismissCount = 0
        isShowing = false
        lastText = nil
    }
}
