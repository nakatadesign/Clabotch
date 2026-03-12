import Foundation
import os.log

/// StateMachine → 下流コンポーネントの結線を担当する Coordinator。
/// AppDelegate から抽出し、自動テストで結線パスを直接検証可能にする。
final class CoordinatorBinder {
    let stateMachine: StateMachine
    let gazeController: GazeController
    let blinkController: BlinkController
    weak var eyeView: ClabotchEyeView?
    let activeBubble: BubblePresenting
    let ephemeralBubble: BubblePresenting
    var anchorProvider: () -> CGPoint?

    init(
        stateMachine: StateMachine,
        gazeController: GazeController,
        blinkController: BlinkController,
        eyeView: ClabotchEyeView?,
        activeBubble: BubblePresenting,
        ephemeralBubble: BubblePresenting,
        anchorProvider: @escaping () -> CGPoint?
    ) {
        self.stateMachine = stateMachine
        self.gazeController = gazeController
        self.blinkController = blinkController
        self.eyeView = eyeView
        self.activeBubble = activeBubble
        self.ephemeralBubble = ephemeralBubble
        self.anchorProvider = anchorProvider
    }

    /// StateMachine の callback を設定する。AppDelegate.applicationDidFinishLaunching から呼ばれる。
    func bind() {
        // GazeController → ClabotchEyeView
        gazeController.onGazeFrameChanged = { [weak self] frame in
            self?.eyeView?.setGazeFrame(frame)
        }

        // BlinkController → ClabotchEyeView
        blinkController.onBlink = { [weak self] in
            self?.eyeView?.triggerBlink()
        }

        // StateMachine → Coordinator fan-out
        stateMachine.onPhaseChanged = { [weak self] phase in
            guard let self else { return }
            os_log(.info, "フェーズ変更: %{public}@", Self.phaseName(phase))

            let override = Self.gazeOverride(for: phase)
            self.gazeController.setOverride(override)

            let blinkEnabled = Self.isBlinkEnabled(for: phase)
            self.blinkController.setBlinking(enabled: blinkEnabled)

            self.eyeView?.setPhaseAppearance(phase: phase)

            // §5: DONE 時にジャンプアニメーション（DONE スピンとは独立して動作）
            if case .done = phase {
                self.eyeView?.performJump()
            }

            if let text = Self.bubbleText(for: phase) {
                if let anchor = self.anchorProvider() {
                    self.activeBubble.show(text: text, anchor: anchor)
                }
            } else {
                self.activeBubble.dismiss()
            }
        }

        stateMachine.onEphemeralDone = { [weak self] elapsedMs in
            guard let self else { return }
            let text = Self.formatElapsedTime(elapsedMs)
            let display = "別セッション完了 (\(text))"
            if var anchor = self.anchorProvider() {
                // activeBubble 表示中なら下にずらして重なりを回避
                if self.activeBubble.isShowing {
                    anchor.y -= Self.bubbleStackOffset
                }
                self.ephemeralBubble.show(text: display, anchor: anchor, duration: 2.0)
            }
        }
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

    // MARK: - 定数

    /// activeBubble 表示中に ephemeralBubble を下にずらすオフセット（ポイント）
    static let bubbleStackOffset: CGFloat = 30

    // MARK: - ヘルパー

    /// ログ出力用の phase 名。associated value（error message 等）を含めない。
    static func phaseName(_ phase: MascotPhase) -> String {
        switch phase {
        case .idle:     return "idle"
        case .thinking: return "thinking"
        case .working:  return "working"
        case .done:     return "done"
        case .error:    return "error"
        case .sleeping: return "sleeping"
        }
    }

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
}
