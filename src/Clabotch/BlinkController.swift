import Foundation

/// まばたき制御コントローラー。main thread 専用。
/// v11 §6: 通常（idle, thinking, working, done）→ 2.8〜5.5秒ランダム間隔でまばたき
///         停止（error, sleeping）→ まばたきなし
final class BlinkController {

    // MARK: - Callback

    /// まばたき発生時に呼ばれる。描画層が購読する。
    var onBlink: (() -> Void)?

    // MARK: - Properties

    private let intervalRange: ClosedRange<Double>
    private let randomSource: () -> Double  // 0.0..<1.0 のランダム値を返す
    private var blinkTimer: Timer?
    private(set) var isBlinking: Bool = false

    // MARK: - Init

    init(
        intervalRange: ClosedRange<Double> = 2.8...5.5,
        randomSource: @escaping () -> Double = { Double.random(in: 0.0..<1.0) }
    ) {
        self.intervalRange = intervalRange
        self.randomSource = randomSource
    }

    // MARK: - Public API

    /// まばたきの有効/無効を切り替える。
    /// AppDelegate が onPhaseChanged を受けて呼ぶ。
    /// enabled=true: タイマー開始。既に開始済みの場合はタイマーをリセットする
    ///   （phase 変更のたびに呼ばれるため、まばたき間隔がリセットされる。
    ///    これは意図した挙動: phase 切り替え直後にまばたきせず、一拍おく）
    /// enabled=false: タイマー停止
    func setBlinking(enabled: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        isBlinking = enabled
        if enabled {
            scheduleNextBlink()
        } else {
            blinkTimer?.invalidate()
            blinkTimer = nil
        }
    }

    // MARK: - Private

    private func scheduleNextBlink() {
        blinkTimer?.invalidate()
        let interval = intervalRange.lowerBound
            + randomSource() * (intervalRange.upperBound - intervalRange.lowerBound)
        blinkTimer = Timer.scheduledTimer(
            withTimeInterval: interval, repeats: false
        ) { [weak self] _ in
            guard let self, self.isBlinking else { return }
            self.onBlink?()
            self.scheduleNextBlink()
        }
    }
}
