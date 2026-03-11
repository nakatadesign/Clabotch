import AppKit

/// メニューバー上のマスコット描画ビュー。main thread 専用。
/// PNG 素材ゼロ — 全フレームを Core Graphics で描画。
/// v11 §3-§4, §8 準拠。
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

    // MARK: - 状態（private(set) でテストから参照可能）

    private(set) var gazeFrame: GazeFrame = .f02_rightDown
    private(set) var isBlinkClosed: Bool = false
    private(set) var faceColor: NSColor = Palette.faceNormal
    private(set) var showErrorX: Bool = false
    private(set) var showSurprise: Bool = false
    private var blinkTimer: Timer?

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        blinkTimer?.invalidate()
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
        case .error:
            faceColor = Palette.faceError
            showErrorX = true
            showSurprise = false
            isBlinkClosed = false
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

    // MARK: - 描画

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let dot = min(bounds.width / Self.canvasWidth, bounds.height / Self.canvasHeight)

        // 背景クリア（メニューバーは透明）
        ctx.clear(bounds)

        // 顔（16×12 at (3,1)）
        drawFace(ctx: ctx, dot: dot)

        if isBlinkClosed {
            // まばたき / sleeping: 閉じ目（frame06）
            drawBlinkClosed(ctx: ctx, dot: dot)
        } else if showErrorX {
            // エラー: ×マーク（frame07）
            drawEyeSockets(ctx: ctx, dot: dot)
            drawErrorX(ctx: ctx, dot: dot)
        } else if showSurprise {
            // 驚き: 中央瞳（frame08）
            drawEyeSockets(ctx: ctx, dot: dot)
            drawPupils(ctx: ctx, dot: dot, frame: .f01_center)
        } else {
            // 通常: 目 + 瞳
            drawEyeSockets(ctx: ctx, dot: dot)
            drawPupils(ctx: ctx, dot: dot, frame: gazeFrame)
        }
    }

    // MARK: - 描画ヘルパー

    private func px(_ ctx: CGContext, _ x: CGFloat, _ y: CGFloat,
                    _ w: CGFloat, _ h: CGFloat, _ dot: CGFloat) {
        // v11 §8: dot 単位のピクセル描画
        // NSView は左下原点なので Y を反転する
        let flippedY = Self.canvasHeight - y - h
        ctx.fill(CGRect(x: x * dot, y: flippedY * dot, width: w * dot, height: h * dot))
    }

    private func drawFace(ctx: CGContext, dot: CGFloat) {
        ctx.setFillColor(faceColor.cgColor)
        // face: 16×12 at (3, 1)
        px(ctx, 3, 1, 16, 12, dot)
    }

    private func drawEyeSockets(ctx: CGContext, dot: CGFloat) {
        ctx.setFillColor(Palette.eyeWhite.cgColor)
        // 左目ソケット: 4×8 at (5, 3)
        px(ctx, 5, 3, 4, 8, dot)
        // 右目ソケット: 4×8 at (13, 3)
        px(ctx, 13, 3, 4, 8, dot)
    }

    /// v11 §4, §8: フレーム丸ごと切り替え（座標計算禁止）
    private func drawPupils(ctx: CGContext, dot: CGFloat, frame: GazeFrame) {
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
        px(ctx, lx, ly, 2, 6, dot)
        px(ctx, rx, ry, 2, 6, dot)
    }

    private func drawBlinkClosed(ctx: CGContext, dot: CGFloat) {
        // frame06: 閉じ目 — 目のソケット領域に横線を描画
        ctx.setFillColor(Palette.pupil.cgColor)
        // 左目: 4×1 at (5, 7) — ソケットの中央付近
        px(ctx, 5, 7, 4, 1, dot)
        // 右目: 4×1 at (13, 7) — ソケットの中央付近
        px(ctx, 13, 7, 4, 1, dot)
    }

    private func drawErrorX(ctx: CGContext, dot: CGFloat) {
        ctx.setFillColor(Palette.errorX.cgColor)
        // 左目に × — 対角線を2×2ドットで表現
        px(ctx, 5, 4, 2, 2, dot)
        px(ctx, 7, 6, 2, 2, dot)
        px(ctx, 5, 6, 2, 2, dot)
        px(ctx, 7, 4, 2, 2, dot)
        // 右目に ×
        px(ctx, 13, 4, 2, 2, dot)
        px(ctx, 15, 6, 2, 2, dot)
        px(ctx, 13, 6, 2, 2, dot)
        px(ctx, 15, 4, 2, 2, dot)
    }
}
