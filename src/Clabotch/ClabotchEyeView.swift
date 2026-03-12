import AppKit

/// メニューバー上のマスコット描画ビュー。main thread 専用。
/// PNG 素材ゼロ — 全フレームを Core Graphics で描画。
/// v11 §3-§4, §8 準拠。patch_011 でフレーム 09〜14 追加。
final class ClabotchEyeView: NSView {

    // MARK: - 定数

    /// キャンバスサイズ（論理ピクセル）
    static let canvasWidth: CGFloat = 22
    static let canvasHeight: CGFloat = 14

    /// カラーパレット（v11 §3）
    enum Palette {
        static let faceNormal  = NSColor(red: 0xB0/255.0, green: 0x78/255.0, blue: 0x78/255.0, alpha: 1)
        static let faceDone    = NSColor(red: 0xC0/255.0, green: 0x88/255.0, blue: 0x88/255.0, alpha: 1)
        static let faceError   = NSColor(red: 0xC0/255.0, green: 0x68/255.0, blue: 0x68/255.0, alpha: 1)
        static let faceSleep   = NSColor(red: 0x90/255.0, green: 0x60/255.0, blue: 0x60/255.0, alpha: 1)
        static let eyeWhite    = NSColor(red: 0xF0/255.0, green: 0xF0/255.0, blue: 0xF0/255.0, alpha: 1)
        static let pupil       = NSColor(red: 0x1A/255.0, green: 0x1A/255.0, blue: 0x1A/255.0, alpha: 1)
        static let errorX      = NSColor(red: 0xE9/255.0, green: 0x45/255.0, blue: 0x60/255.0, alpha: 1)
        static let thinkingDot = NSColor(red: 0x55/255.0, green: 0x77/255.0, blue: 0xAA/255.0, alpha: 1)
    }

    // MARK: - アニメーション定数（patch_011）

    /// DONE アニメーション: 瞳位置の時計回りスピン（§4: 08→09→12→13→14→13→12）
    static let doneAnimSequence: [GazeFrame] = [
        .f01_center,    // frame 08: 驚き（中央瞳）
        .f05_rightUp,   // frame 09: 右上
        .f02_rightDown, // frame 12: 右下
        .f03_leftDown,  // frame 13: 左下
        .f04_leftUp,    // frame 14: 左上（頂点）
        .f03_leftDown,  // frame 13: 左下（復路）
        .f02_rightDown, // frame 12: 右下（停止）
    ]

    /// ERROR アニメーション: 顔全体の Y オフセット（§4: 07→10→11→10→07）
    static let errorShakeSequence: [CGFloat] = [
        0,  // frame 07: 通常位置
        -1, // frame 10: 1dot 上
        1,  // frame 11: 1dot 下
        -1, // frame 10: 1dot 上（復路）
        0,  // frame 07: 通常位置（停止）
    ]

    /// DONE アニメーション各ステップの間隔
    static let doneAnimInterval: TimeInterval = 0.12

    /// ERROR アニメーション各ステップの間隔
    static let errorShakeInterval: TimeInterval = 0.08

    /// ジャンプアニメーション: Y オフセット（ポイント）のシーケンス（§5 定義）
    static let jumpSequence: [CGFloat] = [6, 12, 4, 0]

    /// ジャンプアニメーション各ステップの間隔
    static let jumpInterval: TimeInterval = 0.08

    // MARK: - 状態（private(set) でテストから参照可能）

    private(set) var gazeFrame: GazeFrame = .f02_rightDown
    private(set) var isBlinkClosed: Bool = false
    private(set) var faceColor: NSColor = Palette.faceNormal
    private(set) var showErrorX: Bool = false
    private(set) var showSurprise: Bool = false
    private var blinkTimer: Timer?

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
    /// 簡易実装: open → closed(150ms) → open
    func triggerBlink() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isBlinkClosed else { return }
        isBlinkClosed = true
        needsDisplay = true

        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.isBlinkClosed = false
            self.needsDisplay = true
        }
    }

    /// phase に応じた外見を設定する。AppDelegate が onPhaseChanged で呼ぶ。
    func setPhaseAppearance(phase: MascotPhase) {
        dispatchPrecondition(condition: .onQueue(.main))

        // 前のアニメーションを停止
        stopAnimation()

        switch phase {
        case .idle, .thinking, .working:
            faceColor = Palette.faceNormal
            showErrorX = false
            showSurprise = false
            isBlinkClosed = false  // sleeping からの復帰時にリセット
        case .done:
            faceColor = Palette.faceDone
            showErrorX = false
            showSurprise = true
            isBlinkClosed = false
            startDoneAnimation()
        case .error:
            faceColor = Palette.faceError
            showErrorX = true
            showSurprise = false
            isBlinkClosed = false
            startErrorShakeAnimation()
        case .sleeping:
            faceColor = Palette.faceSleep
            showErrorX = false
            showSurprise = false
            blinkTimer?.invalidate()  // 進行中の blink reopen を無効化
            blinkTimer = nil
            isBlinkClosed = true  // v11 §6: sleeping は frame06（常時閉じ目）
        }
        needsDisplay = true
    }

    // MARK: - アニメーション制御（patch_011）

    /// DONE アニメーションを開始する。
    private func startDoneAnimation() {
        animationStep = 0
        doneAnimPupilFrame = Self.doneAnimSequence[0]

        animationTimer = Timer.scheduledTimer(
            withTimeInterval: Self.doneAnimInterval,
            repeats: true
        ) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.animationStep += 1
            if self.animationStep < Self.doneAnimSequence.count {
                self.doneAnimPupilFrame = Self.doneAnimSequence[self.animationStep]
                self.needsDisplay = true
            } else {
                // アニメーション完了 — 最終フレームの瞳位置を維持
                timer.invalidate()
                self.animationTimer = nil
            }
        }
    }

    /// ERROR シェイクアニメーションを開始する。
    private func startErrorShakeAnimation() {
        animationStep = 0
        shakeYOffset = Self.errorShakeSequence[0]

        animationTimer = Timer.scheduledTimer(
            withTimeInterval: Self.errorShakeInterval,
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
        stopJump()
        isJumping = true
        jumpStep = 0

        // 初期位置を適用
        applyJumpOffset(Self.jumpSequence[0])

        jumpTimer = Timer.scheduledTimer(
            withTimeInterval: Self.jumpInterval,
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

    /// 進行中のアニメーション（DONE スピン / ERROR シェイク / ジャンプ）を停止し状態をリセットする。
    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        animationStep = 0
        doneAnimPupilFrame = nil
        shakeYOffset = 0
        stopJump()
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

        // ERROR シェイク: 全描画に Y オフセットを適用（patch_011）
        let dy = Self.shakeOffsetToViewDY(logicalOffset: shakeYOffset, dot: dot)

        // 背景クリア（メニューバーは透明）
        ctx.clear(bounds)

        // 顔（16×12 at (3,1)）
        drawFace(ctx: ctx, dot: dot, ox: ox, oy: oy, dy: dy)

        if isBlinkClosed {
            // まばたき / sleeping: 閉じ目（frame06）
            drawBlinkClosed(ctx: ctx, dot: dot, ox: ox, oy: oy, dy: dy)
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
            // 通常: 目 + 瞳
            drawEyeSockets(ctx: ctx, dot: dot, ox: ox, oy: oy, dy: dy)
            drawPupils(ctx: ctx, dot: dot, ox: ox, oy: oy, dy: dy, frame: gazeFrame)
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
        ctx.setFillColor(faceColor.cgColor)
        // face: 16×12 at (3, 1)
        px(ctx, 3, 1, 16, 12, dot, ox: ox, oy: oy, dy: dy)
    }

    private func drawEyeSockets(ctx: CGContext, dot: CGFloat, ox: CGFloat, oy: CGFloat, dy: CGFloat = 0) {
        ctx.setFillColor(Palette.eyeWhite.cgColor)
        // 左目ソケット: 4×8 at (5, 3)
        px(ctx, 5, 3, 4, 8, dot, ox: ox, oy: oy, dy: dy)
        // 右目ソケット: 4×8 at (13, 3)
        px(ctx, 13, 3, 4, 8, dot, ox: ox, oy: oy, dy: dy)
    }

    /// v11 §4, §8: フレーム丸ごと切り替え（座標計算禁止）
    private func drawPupils(ctx: CGContext, dot: CGFloat, ox: CGFloat, oy: CGFloat,
                            dy: CGFloat = 0, frame: GazeFrame) {
        ctx.setFillColor(Palette.pupil.cgColor)

        // 左目ソケット基点: (sx=5, sy=3)
        // 右目ソケット基点: (sx=13, sy=3)
        let (lx, ly, rx, ry): (CGFloat, CGFloat, CGFloat, CGFloat) = {
            switch frame {
            case .f01_center:    return (5+1, 3+1, 13+1, 3+1)    // 中央
            case .f02_rightDown: return (5+2, 3+2, 13+2, 3+2)    // 右下
            case .f03_leftDown:  return (5+0, 3+2, 13+0, 3+2)    // 左下
            case .f04_leftUp:    return (5+0, 3+0, 13+0, 3+0)    // 左上
            case .f05_rightUp:   return (5+2, 3+0, 13+2, 3+0)    // 右上
            }
        }()

        // 瞳: 2×6
        px(ctx, lx, ly, 2, 6, dot, ox: ox, oy: oy, dy: dy)
        px(ctx, rx, ry, 2, 6, dot, ox: ox, oy: oy, dy: dy)
    }

    private func drawBlinkClosed(ctx: CGContext, dot: CGFloat, ox: CGFloat, oy: CGFloat, dy: CGFloat = 0) {
        // frame06: 閉じ目 — 目のソケット領域に横線を描画
        ctx.setFillColor(Palette.pupil.cgColor)
        // 左目: 4×1 at (5, 7) — ソケットの中央付近
        px(ctx, 5, 7, 4, 1, dot, ox: ox, oy: oy, dy: dy)
        // 右目: 4×1 at (13, 7) — ソケットの中央付近
        px(ctx, 13, 7, 4, 1, dot, ox: ox, oy: oy, dy: dy)
    }

    private func drawErrorX(ctx: CGContext, dot: CGFloat, ox: CGFloat, oy: CGFloat, dy: CGFloat = 0) {
        ctx.setFillColor(Palette.errorX.cgColor)
        // 左目に × — 対角線を2×2ドットで表現
        px(ctx, 5, 4, 2, 2, dot, ox: ox, oy: oy, dy: dy)
        px(ctx, 7, 6, 2, 2, dot, ox: ox, oy: oy, dy: dy)
        px(ctx, 5, 6, 2, 2, dot, ox: ox, oy: oy, dy: dy)
        px(ctx, 7, 4, 2, 2, dot, ox: ox, oy: oy, dy: dy)
        // 右目に ×
        px(ctx, 13, 4, 2, 2, dot, ox: ox, oy: oy, dy: dy)
        px(ctx, 15, 6, 2, 2, dot, ox: ox, oy: oy, dy: dy)
        px(ctx, 13, 6, 2, 2, dot, ox: ox, oy: oy, dy: dy)
        px(ctx, 15, 4, 2, 2, dot, ox: ox, oy: oy, dy: dy)
    }
}
