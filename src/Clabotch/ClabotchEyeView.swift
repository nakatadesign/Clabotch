import AppKit
import os.log

/// メニューバー上のマスコット描画ビュー。main thread 専用。
/// PNG 素材ゼロ — 全フレームを Core Graphics で描画。
/// v11 §3-§4, §8 準拠。patch_011 でフレーム 09〜14、patch_012 でまばたき中間フレーム追加。
final class ClabotchEyeView: NSView {

    // MARK: - 定数

    /// キャンバスサイズ（論理ピクセル）
    static let canvasWidth: CGFloat = 20
    static let canvasHeight: CGFloat = 14

    /// カラーパレット（v11 §3）
    enum Palette {
        static let faceNormal  = NSColor(red: 0xB0/255.0, green: 0x78/255.0, blue: 0x78/255.0, alpha: 1) // #B07878 ピンクブラウン
        static let faceDone    = NSColor(red: 0xD0/255.0, green: 0xA8/255.0, blue: 0x70/255.0, alpha: 1) // #D0A870 暖かいゴールド
        static let faceError   = NSColor(red: 0xD0/255.0, green: 0x48/255.0, blue: 0x48/255.0, alpha: 1) // #D04848 明確な赤
        static let faceSleep   = NSColor(red: 0x78/255.0, green: 0x68/255.0, blue: 0x88/255.0, alpha: 1) // #786888 青紫（眠い感）
        static let eyeWhite    = NSColor(red: 0xF0/255.0, green: 0xF0/255.0, blue: 0xF0/255.0, alpha: 1)
        static let pupil       = NSColor(red: 0x1A/255.0, green: 0x1A/255.0, blue: 0x1A/255.0, alpha: 1)
        static let errorX      = NSColor(red: 0xE9/255.0, green: 0x45/255.0, blue: 0x60/255.0, alpha: 1)
        static let thinkingDot = NSColor(red: 0x55/255.0, green: 0x77/255.0, blue: 0xAA/255.0, alpha: 1)
    }

    /// まばたきの段階（patch_012: §4 blink シーケンス）
    enum BlinkStage: Equatable, CaseIterable {
        case open     // 目が開いている（通常描画）
        case half     // 半閉じ: ソケット 4×4, 瞳 2×2
        case almost   // ほぼ閉じ: ソケット 4×2, 瞳なし
        case closed   // 完全閉じ: 横線 4×1（frame06）
    }

    // MARK: - アニメーション定数

    /// THINKING アニメーション: 視線を右上⇔左上に交互
    static let thinkingAnimSequence: [(frame: GazeFrame, yOffset: CGFloat)] = [
        (.f05_rightUp, 0),
        (.f04_leftUp,  0),
    ]

    /// THINKING アニメーション各ステップの間隔。
    /// テストや実機チューニングのために変更可能。
    static let defaultThinkingAnimInterval: TimeInterval = 0.8
    var thinkingAnimInterval: TimeInterval = defaultThinkingAnimInterval

    /// RESPONDING アニメーション: 中央⇔左下をゆっくり交互（「書いている」感）
    static let respondingAnimSequence: [GazeFrame] = [
        .f01_center,
        .f03_leftDown,
    ]

    /// RESPONDING アニメーション各ステップの間隔（thinking より遅く、静かな印象）。
    /// テストや実機チューニングのために変更可能。
    static let defaultRespondingAnimInterval: TimeInterval = 2.0
    var respondingAnimInterval: TimeInterval = defaultRespondingAnimInterval

    /// DONE アニメーション: 左下から時計回り2周 → 左下で停止
    static let doneAnimSequence: [GazeFrame] = [
        .f03_leftDown,  // 起点（左下）
        // 1周目
        .f04_leftUp,    // 左上
        .f05_rightUp,   // 右上
        .f02_rightDown, // 右下
        .f03_leftDown,  // 左下
        // 2周目
        .f04_leftUp,    // 左上
        .f05_rightUp,   // 右上
        .f02_rightDown, // 右下
        .f03_leftDown,  // 左下（停止）
    ]

    /// ERROR アニメーション: 顔全体の Y オフセット（§4: 07→10→11→10→07）
    static let errorShakeSequence: [CGFloat] = [
        0,  // frame 07: 通常位置
        -1, // frame 10: 1dot 上
        1,  // frame 11: 1dot 下
        -1, // frame 10: 1dot 上（復路）
        0,  // frame 07: 通常位置（停止）
    ]

    /// まばたきシーケンス（白目維持 + 黒目横線で瞬き）
    /// 各要素は (段階, 保持時間)
    static let blinkSequence: [(stage: BlinkStage, duration: TimeInterval)] = [
        (.closed, 0.12),  // 120ms
    ]

    /// DONE アニメーション各ステップの間隔。
    /// テストや実機チューニングのために変更可能。
    static let defaultDoneAnimInterval: TimeInterval = 0.12
    var doneAnimInterval: TimeInterval = defaultDoneAnimInterval

    /// ERROR アニメーション各ステップの間隔。
    /// テストや実機チューニングのために変更可能。
    static let defaultErrorShakeInterval: TimeInterval = 0.08
    var errorShakeInterval: TimeInterval = defaultErrorShakeInterval

    /// ジャンプアニメーション: Y オフセット（ポイント）のシーケンス（§5 定義）
    static let jumpSequence: [CGFloat] = [6, 12, 4, 0, 4, 8, 2, 0]

    /// ジャンプアニメーション各ステップの間隔。
    /// テストや実機チューニングのために変更可能。
    static let defaultJumpInterval: TimeInterval = 0.08
    var jumpInterval: TimeInterval = defaultJumpInterval

    // MARK: - 状態（private(set) でテストから参照可能）

    private(set) var gazeFrame: GazeFrame = .f03_leftDown
    /// まばたきの現在の段階。.open 以外はまばたき中。
    private(set) var blinkStage: BlinkStage = .open
    private(set) var faceColor: NSColor = Palette.faceNormal
    private(set) var showErrorX: Bool = false
    private(set) var showSurprise: Bool = false
    private(set) var showSleepingEyes: Bool = false
    private(set) var showHappyEyes: Bool = false
    private var blinkTimer: Timer?

    /// 後方互換: まばたき中（open 以外）かどうか
    var isBlinkClosed: Bool { blinkStage != .open }

    // MARK: - アニメーション状態（patch_011）

    /// DONE アニメーション中の瞳位置。nil = アニメなし。
    private(set) var doneAnimPupilFrame: GazeFrame?

    /// ERROR シェイク中の Y オフセット（dot 単位）。0 = 通常位置。
    private(set) var shakeYOffset: CGFloat = 0

    /// アニメーション駆動タイマー
    private var animationTimer: Timer?

    /// アニメーション現在ステップ（内部管理用）
    private var animationStep: Int = 0

    /// ジャンプアニメーション中かどうか
    private(set) var isJumping: Bool = false

    /// ジャンプ駆動タイマー（DONE アニメーションとは独立）
    private var jumpTimer: Timer?

    /// ジャンプ現在ステップ
    private var jumpStep: Int = 0

    /// まばたきシーケンスの現在ステップ
    private var blinkSeqStep: Int = 0

    /// THINKING アニメーション中の視線フレーム。nil = アニメなし。
    private(set) var thinkingAnimFrame: GazeFrame?

    /// THINKING アニメーション駆動タイマー
    private var thinkingTimer: Timer?

    /// THINKING アニメーション現在ステップ
    private var thinkingStep: Int = 0

    /// RESPONDING アニメーション中の視線フレーム。nil = アニメなし。
    private(set) var respondingAnimFrame: GazeFrame?

    /// RESPONDING アニメーション駆動タイマー
    private var respondingTimer: Timer?

    /// RESPONDING アニメーション現在ステップ
    private var respondingStep: Int = 0

    /// DONE 虹色グラデーションアニメーションタイマー
    private var rainbowTimer: Timer?
    /// 虹色グラデーションの基準色相（0.0〜1.0）
    private(set) var rainbowHue: CGFloat = 0
    /// 虹色グラデーションが有効か
    private(set) var isRainbowActive: Bool = false

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        blinkTimer?.invalidate()
        animationTimer?.invalidate()
        jumpTimer?.invalidate()
        rainbowTimer?.invalidate()
        thinkingTimer?.invalidate()
        respondingTimer?.invalidate()
    }

    // MARK: - クリック透過（NSStatusBarButton にイベントを委譲）

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: - Public API

    /// 視線フレームを設定する。GazeController.onGazeFrameChanged から呼ばれる。
    func setGazeFrame(_ frame: GazeFrame) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard gazeFrame != frame else { return }
        gazeFrame = frame
        needsDisplay = true
    }

    /// まばたきを発火する。BlinkController.onBlink から呼ばれる。
    /// §4: open → half(60ms) → almost(60ms) → closed(90ms) → almost(60ms) → half(60ms) → open
    func triggerBlink() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard blinkStage == .open else { return }

        blinkSeqStep = 0
        advanceBlinkSequence()
    }

    /// メニュー表示中にエラー目（×マーク）を表示する。顔色は変えない。
    func showMenuFace() {
        dispatchPrecondition(condition: .onQueue(.main))
        showErrorX = true
        needsDisplay = true
    }

    /// メニュー閉じたらエラー目を解除する。
    func hideMenuFace() {
        dispatchPrecondition(condition: .onQueue(.main))
        showErrorX = false
        needsDisplay = true
    }

    /// phase に応じた外見を設定する。AppDelegate が onPhaseChanged で呼ぶ。
    func setPhaseAppearance(phase: MascotPhase) {
        dispatchPrecondition(condition: .onQueue(.main))

        // 前のアニメーションを停止
        stopAnimation()

        switch phase {
        case .idle:
            faceColor = Palette.faceNormal
            showErrorX = false
            showSurprise = false
            showSleepingEyes = false
            showHappyEyes = false
            cancelBlink()
        case .thinking:
            faceColor = Palette.faceNormal
            showErrorX = false
            showSurprise = false
            showSleepingEyes = false
            showHappyEyes = false
            cancelBlink()
            startThinkingAnimation()
        case .responding:
            faceColor = Palette.faceNormal
            showErrorX = false
            showSurprise = false
            showSleepingEyes = false
            showHappyEyes = false
            cancelBlink()
            startRespondingAnimation()
        case .working:
            faceColor = Palette.faceDone  // 暖かいゴールド
            showErrorX = false
            showSurprise = false
            showSleepingEyes = false
            showHappyEyes = false
            cancelBlink()
        case .done:
            faceColor = Palette.faceDone
            showErrorX = false
            showSurprise = true
            showSleepingEyes = false
            showHappyEyes = false
            cancelBlink()
            startDoneAnimation()
            startRainbowAnimation()
        case .error:
            faceColor = Palette.faceError
            showErrorX = true
            showSurprise = false
            showSleepingEyes = false
            showHappyEyes = false
            cancelBlink()
            startErrorShakeAnimation()
        case .sleeping:
            faceColor = Palette.faceSleep
            showErrorX = false
            showSurprise = false
            showSleepingEyes = true
            blinkTimer?.invalidate()
            blinkTimer = nil
            blinkStage = .open
        }
        os_log(.default, "🎨 EyeView: phase=%{public}@ faceColor=%{public}@ errorX=%d surprise=%d blinkStage=%{public}@",
               phase.debugName, Self.colorHex(faceColor),
               showErrorX ? 1 : 0, showSurprise ? 1 : 0, String(describing: blinkStage))
        needsDisplay = true
    }

    // MARK: - まばたきシーケンス制御（patch_012）

    /// まばたきシーケンスを次のステップに進める。
    private func advanceBlinkSequence() {
        guard blinkSeqStep < Self.blinkSequence.count else {
            // シーケンス完了 — open に戻る
            blinkStage = .open
            blinkTimer?.invalidate()
            blinkTimer = nil
            needsDisplay = true
            return
        }

        let step = Self.blinkSequence[blinkSeqStep]
        blinkStage = step.stage
        needsDisplay = true

        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(
            withTimeInterval: step.duration,
            repeats: false
        ) { [weak self] _ in
            guard let self else { return }
            self.blinkSeqStep += 1
            self.advanceBlinkSequence()
        }
    }

    /// 進行中のまばたきをキャンセルし open に戻す。
    private func cancelBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        blinkStage = .open
        blinkSeqStep = 0
    }

    // MARK: - アニメーション制御（patch_011）

    /// DONE アニメーションを開始する。
    private func startDoneAnimation() {
        os_log(.default, "🎬 EyeView: DONE 瞳スピンアニメーション開始（%d ステップ, 間隔=%.0fms）",
               Self.doneAnimSequence.count, doneAnimInterval * 1000)
        animationStep = 0
        doneAnimPupilFrame = Self.doneAnimSequence[0]

        animationTimer = Timer.scheduledTimer(
            withTimeInterval: doneAnimInterval,
            repeats: true
        ) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.animationStep += 1
            if self.animationStep < Self.doneAnimSequence.count {
                self.doneAnimPupilFrame = Self.doneAnimSequence[self.animationStep]
                self.needsDisplay = true
            } else {
                // アニメーション完了 — ハッピー目（⌒）に切替
                timer.invalidate()
                self.animationTimer = nil
                self.showSurprise = false
                self.showHappyEyes = true
                self.doneAnimPupilFrame = nil
                self.needsDisplay = true
            }
        }
    }

    /// ERROR シェイクアニメーションを開始する。
    private func startErrorShakeAnimation() {
        os_log(.default, "🎬 EyeView: ERROR シェイクアニメーション開始（%d ステップ, 間隔=%.0fms）",
               Self.errorShakeSequence.count, errorShakeInterval * 1000)
        animationStep = 0
        shakeYOffset = Self.errorShakeSequence[0]

        animationTimer = Timer.scheduledTimer(
            withTimeInterval: errorShakeInterval,
            repeats: true
        ) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.animationStep += 1
            if self.animationStep < Self.errorShakeSequence.count {
                self.shakeYOffset = Self.errorShakeSequence[self.animationStep]
                self.needsDisplay = true
            } else {
                // シェイク完了 — オフセットをリセット
                self.shakeYOffset = 0
                self.frame.origin.y = 0
                self.needsDisplay = true
                timer.invalidate()
                self.animationTimer = nil
            }
        }
    }

    /// ジャンプアニメーションを開始する（§5: ↑6px → ↑12px → ↑4px → 原点）。
    /// DONE 瞳スピンとは独立して動作する。CoordinatorBinder から呼ばれる。
    func performJump() {
        dispatchPrecondition(condition: .onQueue(.main))
        os_log(.default, "🎬 EyeView: ジャンプアニメーション開始（%d ステップ, 間隔=%.0fms）",
               Self.jumpSequence.count, jumpInterval * 1000)
        stopJump()
        isJumping = true
        jumpStep = 0

        // 初期位置を適用
        applyJumpOffset(Self.jumpSequence[0])

        jumpTimer = Timer.scheduledTimer(
            withTimeInterval: jumpInterval,
            repeats: true
        ) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.jumpStep += 1
            if self.jumpStep < Self.jumpSequence.count {
                self.applyJumpOffset(Self.jumpSequence[self.jumpStep])
            } else {
                // ジャンプ完了 — 原点に戻す
                self.applyJumpOffset(0)
                self.isJumping = false
                timer.invalidate()
                self.jumpTimer = nil
            }
        }
    }

    /// ジャンプの Y オフセットを適用する。ビューの frame.origin.y を変更。
    private func applyJumpOffset(_ offset: CGFloat) {
        frame.origin.y = offset
    }

    /// ジャンプアニメーションを停止する。
    private func stopJump() {
        jumpTimer?.invalidate()
        jumpTimer = nil
        jumpStep = 0
        isJumping = false
        frame.origin.y = 0
    }

    /// 進行中のアニメーション（THINKING / DONE スピン / ERROR シェイク / ジャンプ / 虹色）を停止し状態をリセットする。
    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        animationStep = 0
        doneAnimPupilFrame = nil
        showHappyEyes = false
        shakeYOffset = 0
        stopThinkingAnimation()
        stopRespondingAnimation()
        stopJump()
        stopRainbow()
    }

    // MARK: - THINKING アニメーション

    /// THINKING アニメーションを開始する。視線が右上⇔左上を繰り返し、微かに上下に揺れる。
    private func startThinkingAnimation() {
        thinkingStep = 0
        let first = Self.thinkingAnimSequence[0]
        thinkingAnimFrame = first.frame
        shakeYOffset = first.yOffset

        thinkingTimer = Timer.scheduledTimer(
            withTimeInterval: thinkingAnimInterval,
            repeats: true
        ) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.thinkingStep = (self.thinkingStep + 1) % Self.thinkingAnimSequence.count
            let step = Self.thinkingAnimSequence[self.thinkingStep]
            self.thinkingAnimFrame = step.frame
            self.shakeYOffset = step.yOffset
            self.needsDisplay = true
        }
    }

    /// THINKING アニメーションを停止する。
    private func stopThinkingAnimation() {
        thinkingTimer?.invalidate()
        thinkingTimer = nil
        thinkingAnimFrame = nil
        thinkingStep = 0
    }

    // MARK: - RESPONDING アニメーション

    /// RESPONDING アニメーションを開始する。中央⇔左下をゆっくり交互に動かす。
    private func startRespondingAnimation() {
        respondingStep = 0
        respondingAnimFrame = Self.respondingAnimSequence[0]

        respondingTimer = Timer.scheduledTimer(
            withTimeInterval: respondingAnimInterval,
            repeats: true
        ) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.respondingStep = (self.respondingStep + 1) % Self.respondingAnimSequence.count
            self.respondingAnimFrame = Self.respondingAnimSequence[self.respondingStep]
            self.needsDisplay = true
        }
    }

    /// RESPONDING アニメーションを停止する。
    private func stopRespondingAnimation() {
        respondingTimer?.invalidate()
        respondingTimer = nil
        respondingAnimFrame = nil
        respondingStep = 0
    }

    // MARK: - 虹色アニメーション

    /// 虹色アニメーションの更新間隔
    private static let rainbowInterval: TimeInterval = 0.05

    /// 虹色の色相変化速度（1回あたりの変化量）
    private static let rainbowHueStep: CGFloat = 0.10

    /// DONE 虹グラデーションアニメーションを開始する。顔全体が虹色グラデーションでスクロールする。
    private func startRainbowAnimation() {
        rainbowHue = 0
        isRainbowActive = true
        rainbowTimer = Timer.scheduledTimer(
            withTimeInterval: Self.rainbowInterval,
            repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            self.rainbowHue -= Self.rainbowHueStep
            if self.rainbowHue < 0.0 { self.rainbowHue += 1.0 }
            self.needsDisplay = true
        }
    }

    /// 虹グラデーションアニメーションを停止する。
    private func stopRainbow() {
        rainbowTimer?.invalidate()
        rainbowTimer = nil
        rainbowHue = 0
        isRainbowActive = false
    }

    // MARK: - 座標変換ヘルパー

    /// 論理 Y オフセット（上が負）を AppKit 座標系（上が正）に変換する。
    /// テストから直接検証可能にするため static メソッドとして公開。
    static func shakeOffsetToViewDY(logicalOffset: CGFloat, dot: CGFloat) -> CGFloat {
        return -logicalOffset * dot
    }

    // MARK: - 描画

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let dot = min(bounds.width / Self.canvasWidth, bounds.height / Self.canvasHeight)

        // キャンバスを bounds 中央に配置するオフセット
        let ox = (bounds.width  - Self.canvasWidth  * dot) / 2
        let oy = (bounds.height - Self.canvasHeight * dot) / 2

        // ERROR シェイク: frame.origin.y でビュー全体を動かす（クリッピング回避）
        let shakeDY = Self.shakeOffsetToViewDY(logicalOffset: shakeYOffset, dot: dot)
        if shakeDY != 0 {
            frame.origin.y = shakeDY
        }
        let dy: CGFloat = 0

        // 背景クリア（メニューバーは透明）
        ctx.clear(bounds)

        // 顔（16×12 at (3,1)）
        drawFace(ctx: ctx, dot: dot, ox: ox, oy: oy, dy: dy)

        switch blinkStage {
        case .closed:
            // 完全閉じ目（frame06）
            drawBlinkClosed(ctx: ctx, dot: dot, ox: ox, oy: oy, dy: dy)
        case .almost:
            // ほぼ閉じ: ソケット 4×2、瞳なし（patch_012）
            drawBlinkAlmost(ctx: ctx, dot: dot, ox: ox, oy: oy, dy: dy)
        case .half:
            // 半閉じ: ソケット 4×4、瞳 2×2（patch_012）
            drawBlinkHalf(ctx: ctx, dot: dot, ox: ox, oy: oy, dy: dy)
        case .open:
            if showHappyEyes {
                // ハッピー: ⌒ 上向きアーチ（done 完了後）
                drawEyeSockets(ctx: ctx, dot: dot, ox: ox, oy: oy, dy: dy)
                drawHappyEyes(ctx: ctx, dot: dot, ox: ox, oy: oy, dy: dy)
            } else if showSleepingEyes {
                // スリープ: ^_^ 閉じ目
                drawEyeSockets(ctx: ctx, dot: dot, ox: ox, oy: oy, dy: dy)
                drawSleepingEyes(ctx: ctx, dot: dot, ox: ox, oy: oy, dy: dy)
            } else if showErrorX {
                // エラー: ×マーク（frame07 / frame10 / frame11）
                drawEyeSockets(ctx: ctx, dot: dot, ox: ox, oy: oy, dy: dy)
                drawErrorX(ctx: ctx, dot: dot, ox: ox, oy: oy, dy: dy)
            } else if showSurprise {
                // DONE アニメーション（frame08〜14）
                let pupilFrame = doneAnimPupilFrame ?? .f01_center
                drawEyeSockets(ctx: ctx, dot: dot, ox: ox, oy: oy, dy: dy)
                drawPupils(ctx: ctx, dot: dot, ox: ox, oy: oy, dy: dy, frame: pupilFrame)
            } else {
                // 通常: 目 + 瞳（thinking/responding アニメーション中はそのフレームを優先）
                let activeFrame = thinkingAnimFrame ?? respondingAnimFrame ?? gazeFrame
                drawEyeSockets(ctx: ctx, dot: dot, ox: ox, oy: oy, dy: dy)
                drawPupils(ctx: ctx, dot: dot, ox: ox, oy: oy, dy: dy, frame: activeFrame)
            }
        }
    }

    // MARK: - 描画ヘルパー

    /// dot 単位のピクセル描画。ox/oy は中央配置オフセット。dy は Y オフセット（シェイク用）。
    private func px(_ ctx: CGContext, _ x: CGFloat, _ y: CGFloat,
                    _ w: CGFloat, _ h: CGFloat, _ dot: CGFloat,
                    ox: CGFloat = 0, oy: CGFloat = 0, dy: CGFloat = 0) {
        // v11 §8: dot 単位のピクセル描画
        // NSView は左下原点なので Y を反転する
        let flippedY = Self.canvasHeight - y - h
        ctx.fill(CGRect(x: x * dot + ox, y: flippedY * dot + oy + dy, width: w * dot, height: h * dot))
    }

    private func drawFace(ctx: CGContext, dot: CGFloat, ox: CGFloat, oy: CGFloat, dy: CGFloat = 0) {
        if isRainbowActive {
            // ultrathink 風グラデーション: オレンジ→ピンク→パープル→ブルー
            let faceWidth: CGFloat = Self.canvasWidth
            for col in 0..<Int(faceWidth) {
                let t = (rainbowHue + CGFloat(col) / faceWidth).truncatingRemainder(dividingBy: 1.0)
                let color = Self.ultrathinkColor(at: t)
                ctx.setFillColor(color.cgColor)
                px(ctx, CGFloat(col), 0, 1, Self.canvasHeight, dot, ox: ox, oy: oy, dy: dy)
            }
        } else {
            ctx.setFillColor(faceColor.cgColor)
            // face: 22×14 — キャンバス全体
            px(ctx, 0, 0, Self.canvasWidth, Self.canvasHeight, dot, ox: ox, oy: oy, dy: dy)
        }
    }

    private func drawEyeSockets(ctx: CGContext, dot: CGFloat, ox: CGFloat, oy: CGFloat, dy: CGFloat = 0) {
        ctx.setFillColor(Palette.eyeWhite.cgColor)
        // 左目ソケット: 5×10 at (2, 2)
        px(ctx, 2, 2, 5, 10, dot, ox: ox, oy: oy, dy: dy)
        // 右目ソケット: 5×10 at (13, 2)
        px(ctx, 13, 2, 5, 10, dot, ox: ox, oy: oy, dy: dy)
    }

    /// フレーム丸ごと切り替え（座標計算禁止）
    private func drawPupils(ctx: CGContext, dot: CGFloat, ox: CGFloat, oy: CGFloat,
                            dy: CGFloat = 0, frame: GazeFrame) {
        ctx.setFillColor(Palette.pupil.cgColor)

        // 左目ソケット基点: (sx=2, sy=2) サイズ 5×10
        // 右目ソケット基点: (sx=13, sy=2) サイズ 5×10
        // 瞳中央: 左(3,4) 右(14,4) サイズ 3×8 — ソケット内で移動幅 1dot(横), 2dot(縦)
        let (lx, ly, rx, ry): (CGFloat, CGFloat, CGFloat, CGFloat) = {
            switch frame {
            case .f01_center:    return (3,   4,   14,   4)      // 中央
            case .f02_rightDown: return (3+1, 4,   14+1, 4)     // 右下
            case .f03_leftDown:  return (3-1, 4,   14-1, 4)     // 左下
            case .f04_leftUp:    return (3-1, 4-2, 14-1, 4-2)   // 左上
            case .f05_rightUp:   return (3+1, 4-2, 14+1, 4-2)   // 右上
            case .f06_right:     return (3+1, 4,   14+1, 4)     // 右（水平）
            case .f07_left:      return (3-1, 4,   14-1, 4)     // 左（水平）
            }
        }()

        // 瞳: 3×8（左下/右下は row 7 で1px 欠けのカスタム形状）
        if frame == .f03_leftDown {
            // 左下: 両目とも右端1px 欠け
            px(ctx, lx, ly,   3, 3, dot, ox: ox, oy: oy, dy: dy)   // rows 4-6
            px(ctx, lx, ly+3, 2, 1, dot, ox: ox, oy: oy, dy: dy)   // row 7（右端欠け）
            px(ctx, lx, ly+4, 3, 4, dot, ox: ox, oy: oy, dy: dy)   // rows 8-11
            px(ctx, rx, ry,   3, 3, dot, ox: ox, oy: oy, dy: dy)
            px(ctx, rx, ry+3, 2, 1, dot, ox: ox, oy: oy, dy: dy)
            px(ctx, rx, ry+4, 3, 4, dot, ox: ox, oy: oy, dy: dy)
        } else if frame == .f02_rightDown || frame == .f05_rightUp {
            // 右下/右上: 左下の水平反転 → 両目とも左端1px 欠け
            px(ctx, lx, ly,   3, 3, dot, ox: ox, oy: oy, dy: dy)   // rows 4-6
            px(ctx, lx+1, ly+3, 2, 1, dot, ox: ox, oy: oy, dy: dy) // row 7（左端欠け）
            px(ctx, lx, ly+4, 3, 4, dot, ox: ox, oy: oy, dy: dy)   // rows 8-11
            px(ctx, rx, ry,   3, 3, dot, ox: ox, oy: oy, dy: dy)
            px(ctx, rx+1, ry+3, 2, 1, dot, ox: ox, oy: oy, dy: dy)
            px(ctx, rx, ry+4, 3, 4, dot, ox: ox, oy: oy, dy: dy)
        } else if frame == .f04_leftUp {
            // 左上: 左下と同じ形状 → 両目とも右端1px 欠け
            px(ctx, lx, ly,   3, 3, dot, ox: ox, oy: oy, dy: dy)
            px(ctx, lx, ly+3, 2, 1, dot, ox: ox, oy: oy, dy: dy)
            px(ctx, lx, ly+4, 3, 4, dot, ox: ox, oy: oy, dy: dy)
            px(ctx, rx, ry,   3, 3, dot, ox: ox, oy: oy, dy: dy)
            px(ctx, rx, ry+3, 2, 1, dot, ox: ox, oy: oy, dy: dy)
            px(ctx, rx, ry+4, 3, 4, dot, ox: ox, oy: oy, dy: dy)
        } else {
            px(ctx, lx, ly, 3, 8, dot, ox: ox, oy: oy, dy: dy)
            px(ctx, rx, ry, 3, 8, dot, ox: ox, oy: oy, dy: dy)
        }
    }

    /// 半閉じ: フルサイズ白目ソケット + 瞳横棒線
    private func drawBlinkHalf(ctx: CGContext, dot: CGFloat, ox: CGFloat, oy: CGFloat, dy: CGFloat = 0) {
        drawEyeSockets(ctx: ctx, dot: dot, ox: ox, oy: oy, dy: dy)
        ctx.setFillColor(Palette.pupil.cgColor)
        // ソケット中央に横線: 5×1 at (3, 7) / (14, 7)
        px(ctx, 2, 7, 5, 1, dot, ox: ox, oy: oy, dy: dy)
        px(ctx, 13, 7, 5, 1, dot, ox: ox, oy: oy, dy: dy)
    }

    /// ほぼ閉じ: フルサイズ白目ソケット + 瞳横棒線
    private func drawBlinkAlmost(ctx: CGContext, dot: CGFloat, ox: CGFloat, oy: CGFloat, dy: CGFloat = 0) {
        drawEyeSockets(ctx: ctx, dot: dot, ox: ox, oy: oy, dy: dy)
        ctx.setFillColor(Palette.pupil.cgColor)
        px(ctx, 2, 7, 5, 1, dot, ox: ox, oy: oy, dy: dy)
        px(ctx, 13, 7, 5, 1, dot, ox: ox, oy: oy, dy: dy)
    }

    /// ハッピー目: ⌒ 上向きアーチ（done 完了後）
    private func drawHappyEyes(ctx: CGContext, dot: CGFloat, ox: CGFloat, oy: CGFloat, dy: CGFloat = 0) {
        ctx.setFillColor(Palette.pupil.cgColor)
        // 左目: (3,6)-(5,6) の3dot + (2,7) と (6,7) の2dot
        px(ctx, 3, 6, 3, 1, dot, ox: ox, oy: oy, dy: dy)
        px(ctx, 2, 7, 1, 1, dot, ox: ox, oy: oy, dy: dy)
        px(ctx, 6, 7, 1, 1, dot, ox: ox, oy: oy, dy: dy)
        // 右目: (14,6)-(16,6) の3dot + (13,7) と (17,7) の2dot
        px(ctx, 14, 6, 3, 1, dot, ox: ox, oy: oy, dy: dy)
        px(ctx, 13, 7, 1, 1, dot, ox: ox, oy: oy, dy: dy)
        px(ctx, 17, 7, 1, 1, dot, ox: ox, oy: oy, dy: dy)
    }

    /// スリープ閉じ目: ^_^ 逆V字
    private func drawSleepingEyes(ctx: CGContext, dot: CGFloat, ox: CGFloat, oy: CGFloat, dy: CGFloat = 0) {
        ctx.setFillColor(Palette.pupil.cgColor)
        // 左目: (2,7) と (6,7) の2dot + (3,8)-(5,8) の3dot
        px(ctx, 2, 7, 1, 1, dot, ox: ox, oy: oy, dy: dy)
        px(ctx, 6, 7, 1, 1, dot, ox: ox, oy: oy, dy: dy)
        px(ctx, 3, 8, 3, 1, dot, ox: ox, oy: oy, dy: dy)
        // 右目: (13,7) と (17,7) の2dot + (14,8)-(16,8) の3dot
        px(ctx, 13, 7, 1, 1, dot, ox: ox, oy: oy, dy: dy)
        px(ctx, 17, 7, 1, 1, dot, ox: ox, oy: oy, dy: dy)
        px(ctx, 14, 8, 3, 1, dot, ox: ox, oy: oy, dy: dy)
    }

    private func drawBlinkClosed(ctx: CGContext, dot: CGFloat, ox: CGFloat, oy: CGFloat, dy: CGFloat = 0) {
        // 閉じ目 — 白目ソケットを残し、瞳の代わりに横棒線
        drawEyeSockets(ctx: ctx, dot: dot, ox: ox, oy: oy, dy: dy)
        ctx.setFillColor(Palette.pupil.cgColor)
        px(ctx, 2, 7, 5, 1, dot, ox: ox, oy: oy, dy: dy)
        px(ctx, 13, 7, 5, 1, dot, ox: ox, oy: oy, dy: dy)
    }

    /// ultrathink 風グラデーションの色を t (0.0〜1.0) で補間する。
    /// オレンジ → ホットピンク → パープル → ブルー → オレンジ のループ。
    static func ultrathinkColor(at t: CGFloat) -> NSColor {
        // 色停止点（ultrathink スクリーンショット準拠）
        let stops: [(r: CGFloat, g: CGFloat, b: CGFloat)] = [
            (0.98, 0.72, 0.50),  // 淡オレンジ #FAB880
            (0.96, 0.55, 0.68),  // 淡ピンク #F58DAD
            (0.80, 0.55, 0.90),  // 淡パープル #CC8CE6
            (0.58, 0.64, 0.94),  // 淡ブルー #94A3F0
        ]
        let count = stops.count
        let scaled = t * CGFloat(count)
        let i = Int(scaled) % count
        let j = (i + 1) % count
        let frac = scaled - floor(scaled)
        let r = stops[i].r + (stops[j].r - stops[i].r) * frac
        let g = stops[i].g + (stops[j].g - stops[i].g) * frac
        let b = stops[i].b + (stops[j].b - stops[i].b) * frac
        return NSColor(red: r, green: g, blue: b, alpha: 1.0)
    }

    /// NSColor を #RRGGBB 文字列に変換する（デバッグログ用）
    static func colorHex(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "?" }
        let r = Int(rgb.redComponent * 255)
        let g = Int(rgb.greenComponent * 255)
        let b = Int(rgb.blueComponent * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    private func drawErrorX(ctx: CGContext, dot: CGFloat, ox: CGFloat, oy: CGFloat, dy: CGFloat = 0) {
        ctx.setFillColor(Palette.pupil.cgColor)
        // 左目: 目を瞑ったパターン
        px(ctx, 3,  4, 1, 1, dot, ox: ox, oy: oy, dy: dy)
        px(ctx, 4,  5, 1, 1, dot, ox: ox, oy: oy, dy: dy)
        px(ctx, 5,  6, 1, 1, dot, ox: ox, oy: oy, dy: dy)
        px(ctx, 3,  7, 1, 1, dot, ox: ox, oy: oy, dy: dy)
        px(ctx, 4,  7, 1, 1, dot, ox: ox, oy: oy, dy: dy)
        px(ctx, 6,  7, 1, 1, dot, ox: ox, oy: oy, dy: dy)
        px(ctx, 5,  8, 1, 1, dot, ox: ox, oy: oy, dy: dy)
        px(ctx, 4,  9, 1, 1, dot, ox: ox, oy: oy, dy: dy)
        px(ctx, 3, 10, 1, 1, dot, ox: ox, oy: oy, dy: dy)
        // 右目: 左目を水平反転
        px(ctx, 16,  4, 1, 1, dot, ox: ox, oy: oy, dy: dy)
        px(ctx, 15,  5, 1, 1, dot, ox: ox, oy: oy, dy: dy)
        px(ctx, 14,  6, 1, 1, dot, ox: ox, oy: oy, dy: dy)
        px(ctx, 16,  7, 1, 1, dot, ox: ox, oy: oy, dy: dy)
        px(ctx, 15,  7, 1, 1, dot, ox: ox, oy: oy, dy: dy)
        px(ctx, 13,  7, 1, 1, dot, ox: ox, oy: oy, dy: dy)
        px(ctx, 14,  8, 1, 1, dot, ox: ox, oy: oy, dy: dy)
        px(ctx, 15,  9, 1, 1, dot, ox: ox, oy: oy, dy: dy)
        px(ctx, 16, 10, 1, 1, dot, ox: ox, oy: oy, dy: dy)
    }
}
