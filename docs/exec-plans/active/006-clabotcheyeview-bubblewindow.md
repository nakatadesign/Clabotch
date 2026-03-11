# 実装計画 006: ClabotchEyeView + BubbleWindow

## 概要

設計書 v11 §3-§5（キャラクター仕様・フレーム一覧・アニメーション定義）、§6（マスコット状態一覧）、§8（実装方針）に基づき、全フレーム描画エンジン（ClabotchEyeView）と吹き出しウィンドウ（BubbleWindow）を実装する。

AppDelegate が Coordinator 役として、GazeController.onGazeFrameChanged / BlinkController.onBlink → ClabotchEyeView、StateMachine.onPhaseChanged → BubbleWindow の結線を行う。

## 正典参照

- 設計書: `docs/design/current/clabotch_design_doc_v11.md`
- §3: キャラクター仕様（L53-86）— キャンバスサイズ、カラーパレット、設計方針
- §4: フレーム一覧（L89-124）— 全14フレームの瞳座標・用途
- §5: アニメーション定義（L128-141）— まばたき・ジャンプ
- §6: マスコット状態一覧（L143-166）— phase ごとの表情・吹き出し文言
- §8: 実装方針（L203-224）— ドット描画の核心原則、Retina対応

## 正典からの逸脱

| # | 内容 | v11 正典 | 本計画 | 理由 |
|---|------|---------|--------|------|
| 1 | まばたきフレームの簡易実装 | §4: `open → half(60ms) → almost(60ms) → closed(06/90ms) → almost → half → open` の7段階 | 初回実装は `open → closed(frame06/150ms) → open` の3段階。half/almost フレームは frame06 と通常フレームの中間描画が必要で、描画座標の追加定義が必要 | MVP 最小実装。half/almost の瞳座標が §4 に明示されていないため、別計画で追加定義する |
| 2 | ジャンプアニメーションの実装延期 | §5: `↑6px → ↑12px → ↑4px → 原点` の4ステップバウンス | 本計画では実装しない。NSStatusItem の Y オフセット操作は NSStatusBar の内部レイアウトに依存し、実装調査が必要 | スコープ制限。ジャンプなしでも done フレームアニメーション + 吹き出しで完了通知は機能する |
| 3 | エラー・完了アニメーションの簡易実装 | §4: エラー `07 → 10 → 11 → 10 → 07`、完了 `08 → 09 → 12 → 13 → 14 → 13 → 12` | frame 07-14 の瞳座標が §4 に明示されていないため、本計画では frame 01-06 の描画と視線フレーム切り替えに集中する。エラー・完了は固定フレーム（error: frame07 = frame01 + ×マーク、done: frame08 = frame01 + 驚き）で表現 | 瞳座標のない frame 09-14 の描画定義が不足しているため、別計画で詳細アニメーションを追加する |
| 4 | NSStatusItem への ClabotchEyeView 埋め込み | v11 では具体的な NSStatusItem への View 埋め込み方法を規定していない | `statusItem.button` に `ClabotchEyeView` をサブビューとして追加し、`statusItem.length = 22 * dot` で固定幅を設定。`button.title = ""` で既存の "C" テキストを除去 | NSStatusItem の標準的な custom view 埋め込み方法 |
| 5 | BubbleWindow の位置計算 | v11 §5 では「完了後に吹き出し（NSWindow, borderless）が 3秒表示」のみ | NSStatusItem の button.window から画面座標を取得し、メニューバーの下に吹き出しを配置。3秒後に自動消去 | v11 に具体的な配置仕様がないため、メニューバー直下を標準位置とする |
| 6 | 顔色の phase 連動 | v11 §3: 通常 `#B07878`、完了 `#C08888`、エラー `#C06868`、スリープ `#906060` | ClabotchEyeView が `setPhaseAppearance(phase:)` メソッドで顔色を切り替える。AppDelegate が onPhaseChanged で呼ぶ | v11 に明示的なメソッド定義がないため追加 |
| 7 | ClabotchEyeView のテスト用内部状態公開 | v11 では描画パラメータの DI を規定していない | 内部状態（gazeFrame, isBlinkClosed, faceColor 等）を `private(set)` にしてテストから参照可能にする。dot は `min(bounds.width / 22.0, bounds.height / 14.0)` で draw() 時に計算（v11 §8 準拠）。外部注入しない | テスタビリティ。dot はビューサイズに依存するため DI より bounds 指定で制御する |

## 前提条件

- [x] 計画 005 完了（GazeController + BlinkController、Codex A）
- [x] 全 141 テスト合格（140 passed, 1 skipped）
- [x] GazeController.onGazeFrameChanged コールバック実装済み
- [x] BlinkController.onBlink コールバック実装済み
- [x] AppDelegate が Coordinator 役として結線済み

## スコープ

**含む:**
- `ClabotchEyeView` class（NSView サブクラス、全フレーム描画）
  - frame 01-06 の描画（視線5方向 + まばたき）
  - frame 07-08 の簡易描画（エラー×マーク + 驚き）
  - 顔色の phase 連動
  - GazeFrame 入力 → 瞳座標切り替え
  - まばたきアニメーション（簡易3段階）
- `BubbleWindow` class（borderless NSWindow）
  - 吹き出しテキスト表示
  - 3秒自動消去
  - メニューバー下に配置
- AppDelegate 結線変更
  - ClabotchEyeView を NSStatusItem に埋め込み
  - GazeController.onGazeFrameChanged → ClabotchEyeView.setGazeFrame
  - BlinkController.onBlink → ClabotchEyeView.triggerBlink
  - StateMachine.onPhaseChanged → ClabotchEyeView.setPhaseAppearance + BubbleWindow.show
  - StateMachine.onEphemeralDone → BubbleWindow.showEphemeral
- テスト

**含まない:**
- frame 09-14 の詳細アニメーション（完了くるくる・エラーシェイク）
- ジャンプアニメーション（NSStatusItem Y オフセット）
- まばたきの half/almost 中間フレーム
- Warp AX 属性ダンプ（別件）
- オンボーディング UI（§11.7）

---

## Step 1: ClabotchEyeView 描画エンジン

### 成果物

`src/Clabotch/ClabotchEyeView.swift`

### 仕様

```swift
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
    private enum Palette {
        static let faceNormal  = NSColor(red: 0xB0/255, green: 0x78/255, blue: 0x78/255, alpha: 1)
        static let faceDone    = NSColor(red: 0xC0/255, green: 0x88/255, blue: 0x88/255, alpha: 1)
        static let faceError   = NSColor(red: 0xC0/255, green: 0x68/255, blue: 0x68/255, alpha: 1)
        static let faceSleep   = NSColor(red: 0x90/255, green: 0x60/255, blue: 0x60/255, alpha: 1)
        static let eyeWhite    = NSColor(red: 0xF0/255, green: 0xF0/255, blue: 0xF0/255, alpha: 1)
        static let pupil       = NSColor(red: 0x1A/255, green: 0x1A/255, blue: 0x1A/255, alpha: 1)
        static let errorX      = NSColor(red: 0xE9/255, green: 0x45/255, blue: 0x60/255, alpha: 1)
        static let thinkingDot = NSColor(red: 0x55/255, green: 0x77/255, blue: 0xAA/255, alpha: 1)
    }

    // MARK: - 状態

    private var gazeFrame: GazeFrame = .f02_rightDown
    private var isBlinkClosed: Bool = false
    private var faceColor: NSColor = Palette.faceNormal
    private var showErrorX: Bool = false
    private var showSurprise: Bool = false
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
            // まばたき: 閉じ目（frame06）— 目のソケットを線で描画
            drawBlinkClosed(ctx: ctx, dot: dot)
        } else if showErrorX {
            // エラー: ×マーク（frame07）
            drawEyeSockets(ctx: ctx, dot: dot)
            drawErrorX(ctx: ctx, dot: dot)
        } else if showSurprise {
            // 驚き: 中央瞳 + 驚きマーク（frame08）
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
```

### 設計根拠

- v11 §3: 22×14px キャンバス、カラーパレット完全準拠
- v11 §4: フレーム 01-06 の瞳座標をそのまま実装
- v11 §8: `dot = min(bounds.width / 22.0, bounds.height / 14.0)` で Retina 自動対応
- v11 §8: 瞳移動は座標計算禁止 → フレーム丸ごと切り替え
- frame 07-08 は §4 の説明に基づく簡易描画（×マーク / 驚き）
- `dispatchPrecondition` で main thread 保証（計画 004, 005 の方針踏襲）

---

## Step 2: BubbleWindow 実装

### 成果物

`src/Clabotch/BubbleWindow.swift`

### 仕様

```swift
import AppKit

/// 吹き出しウィンドウ。メニューバーの下に表示し、自動消去する。
/// v11 §5, §6 準拠。
final class BubbleWindow {

    private var window: NSWindow?
    private var dismissTimer: Timer?

    /// 吹き出しを表示する。既存の吹き出しがあれば差し替える。
    /// - Parameters:
    ///   - text: 表示テキスト
    ///   - anchor: メニューバーアイコンの画面座標
    ///   - duration: 表示秒数（デフォルト 3.0）
    func show(text: String, anchor: CGPoint, duration: TimeInterval = 3.0) {
        dispatchPrecondition(condition: .onQueue(.main))
        dismiss()

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
```

### 設計根拠

- v11 §5: 「完了後に吹き出し（NSWindow, borderless）が 3秒表示」をそのまま実装
- v11 §6: 吹き出し文言は AppDelegate（Coordinator）が phase に基づいて生成し、BubbleWindow は表示のみ
- BubbleWindow は MascotPhase を知らない（責務の分離、計画 005 の方針踏襲）
- `dismiss()` で既存ウィンドウをクリーンアップしてから新規表示

---

## Step 3: AppDelegate 結線変更

### 変更対象

`src/Clabotch/AppDelegate.swift`

### 変更内容

```swift
import AppKit
import os.log

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var hookServer: HookServer?
    private let deduplicator = EventDeduplicator()
    private let stateMachine = StateMachine()
    private let gazeController = GazeController()
    private let blinkController = BlinkController()
    private var eyeView: ClabotchEyeView?
    private let bubbleWindow = BubbleWindow()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // メニューバー設定（22px 固定幅）
        statusItem = NSStatusBar.system.statusItem(withLength: 22)

        // ClabotchEyeView をステータスバーボタンに埋め込む
        if let button = statusItem?.button {
            button.title = ""
            let view = ClabotchEyeView(frame: button.bounds)
            view.autoresizingMask = [.width, .height]
            button.addSubview(view)
            eyeView = view
        }

        // メニュー構築
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit Clabotch", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem?.menu = menu

        // GazeController のステータスアイテム中心座標プロバイダ設定
        gazeController.statusItemCenterProvider = { [weak self] in
            guard let button = self?.statusItem?.button,
                  let window = button.window else { return nil }
            let frameInWindow = button.convert(button.bounds, to: nil)
            let frameOnScreen = window.convertToScreen(frameInWindow)
            return CGPoint(x: frameOnScreen.midX, y: frameOnScreen.midY)
        }

        // GazeController → ClabotchEyeView
        gazeController.onGazeFrameChanged = { [weak self] frame in
            self?.eyeView?.setGazeFrame(frame)
        }

        // BlinkController → ClabotchEyeView
        blinkController.onBlink = { [weak self] in
            self?.eyeView?.triggerBlink()
        }

        // StateMachine コールバック（Coordinator 役）
        stateMachine.onPhaseChanged = { [weak self] phase in
            guard let self else { return }
            os_log(.info, "フェーズ変更: %{public}@", String(describing: phase))

            // GazeController: phase → override 変換
            let override = Self.gazeOverride(for: phase)
            self.gazeController.setOverride(override)

            // BlinkController: phase → enabled 変換
            let blinkEnabled = Self.isBlinkEnabled(for: phase)
            self.blinkController.setBlinking(enabled: blinkEnabled)

            // ClabotchEyeView: phase → 外見変更
            self.eyeView?.setPhaseAppearance(phase: phase)

            // BubbleWindow: phase → 吹き出し表示
            if let text = Self.bubbleText(for: phase) {
                if let anchor = self.statusItemAnchor() {
                    self.bubbleWindow.show(text: text, anchor: anchor)
                }
            } else {
                self.bubbleWindow.dismiss()
            }
        }

        stateMachine.onEphemeralDone = { [weak self] elapsedMs in
            guard let self else { return }
            let text = Self.formatElapsedTime(elapsedMs)
            let display = "別セッション完了 (\(text))"
            if let anchor = self.statusItemAnchor() {
                self.bubbleWindow.show(text: display, anchor: anchor, duration: 2.0)
            }
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
            gazeController.startPolling()
        } catch let error as HookServerError where error == .alreadyRunning {
            os_log(.error, "既に別インスタンスが起動中")
            NSApplication.shared.terminate(nil)
        } catch {
            os_log(.error, "HookServer failed to start: %{public}@", error.localizedDescription)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        bubbleWindow.dismiss()
        blinkController.setBlinking(enabled: false)
        gazeController.stopPolling()
        hookServer?.terminateSync()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
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
        case .error(_, let message):
            if let msg = message {
                return "エラーが出ました… \(msg)"
            } else {
                return "エラーが出ました…"
            }
        case .idle, .sleeping:
            return nil
        }
    }

    // MARK: - ヘルパー

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

    private func statusItemAnchor() -> CGPoint? {
        guard let button = statusItem?.button,
              let window = button.window else { return nil }
        let frameInWindow = button.convert(button.bounds, to: nil)
        let frameOnScreen = window.convertToScreen(frameInWindow)
        return CGPoint(x: frameOnScreen.midX, y: frameOnScreen.minY)
    }
}
```

### 設計根拠

- AppDelegate が Coordinator 役を維持（計画 005 踏襲）
- `statusItemCenterProvider` を `statusItemAnchor()` private メソッドと共用（重複コード削減）
- `bubbleText(for:)` を static メソッドにしてテスト可能に
- `formatElapsedTime(_:)` を static メソッドにしてテスト可能に
- v11 §6 の吹き出し文言規約をそのまま実装
- ephemeral done: `elapsed_ms > 0` のみ 2 秒表示（v11 §6 準拠）

---

## Step 4: テスト

### 成果物

- `src/ClabotchTests/ClabotchEyeViewTests.swift`
- `src/ClabotchTests/BubbleWindowTests.swift`
- `src/ClabotchTests/AppDelegateCoordinatorTests.swift`（既存に追加）

### ClabotchEyeViewTests（10 件）

| # | テスト名 | 検証内容 |
|---|---------|---------|
| 1 | `testInitialState` | 初期状態: gazeFrame == .f02_rightDown, isBlinkClosed == false |
| 2 | `testSetGazeFrameUpdatesState` | setGazeFrame(.f01_center) → needsDisplay == true |
| 3 | `testSetGazeFrameSameFrameNoOp` | 同一 frame 設定 → needsDisplay 変化なし |
| 4 | `testTriggerBlinkSetsClosedState` | triggerBlink() → isBlinkClosed == true |
| 5 | `testBlinkAutoOpens` | triggerBlink() 後 150ms+ → isBlinkClosed == false |
| 6 | `testSetPhaseAppearanceNormal` | idle → faceColor == normal, showErrorX == false |
| 7 | `testSetPhaseAppearanceError` | error → faceColor == error, showErrorX == true |
| 8 | `testSetPhaseAppearanceDone` | done → faceColor == done, showSurprise == true |
| 9 | `testSetPhaseAppearanceSleeping` | sleeping → faceColor == sleep, isBlinkClosed == true |
| 10 | `testSleepingToIdleResetsBlinkClosed` | sleeping → idle → isBlinkClosed == false |

### BubbleWindowTests（4 件）

| # | テスト名 | 検証内容 |
|---|---------|---------|
| 11 | `testShowCreatesWindow` | show() 後に window が存在する |
| 12 | `testDismissClosesWindow` | dismiss() 後に window が nil |
| 13 | `testShowReplacesExisting` | 2回 show() → window は1つ |
| 14 | `testAutoDismissAfterDuration` | show(duration: 0.1) → 0.2秒後に window が nil |

### AppDelegateCoordinatorTests 追加（5 件）

| # | テスト名 | 検証内容 |
|---|---------|---------|
| 15 | `testBubbleTextThinking` | thinking → "考えてます..." |
| 16 | `testBubbleTextDoneWithTime` | done(elapsedMs: 222000) → "完了！(3分42秒)" |
| 17 | `testBubbleTextDoneNoTime` | done(elapsedMs: 0) → "完了！" |
| 18 | `testBubbleTextIdleNil` | idle → nil |
| 19 | `testFormatElapsedTime` | 222000 → "3分42秒", 5000 → "5秒" |

### テスト合計

- ClabotchEyeViewTests: 10 件
- BubbleWindowTests: 4 件
- AppDelegateCoordinatorTests 追加: 5 件
- 既存テスト: 141 件（140 passed, 1 skipped）
- **目標合計: 160 件（159 passed, 1 skipped）**

### テスト設計方針

1. **ClabotchEyeView テスト**: 内部状態（gazeFrame, isBlinkClosed, faceColor 等）を検証。draw() の描画結果はピクセルレベルの検証が困難なため、状態変更とフラグの正確性に集中
2. **BubbleWindow テスト**: NSWindow の生成・消去・自動消去を検証。XCTestExpectation で非同期タイマーを待機
3. **テスト環境**: ClabotchEyeView の内部状態アクセスのために `@testable import` を使用。private プロパティへのアクセスが必要な場合は internal に昇格

---

## Step 5: xcodegen + ビルド + テスト実行

```bash
cd src && xcodegen generate && xcodebuild test -project Clabotch.xcodeproj -scheme Clabotch -destination 'platform=macOS'
```

目標: 160 テスト全通過（159 passed, 1 skipped）

---

## Step 6: Codex 実装レビュー

レビュー観点:
- v11 §3-§4 との描画座標の正確性
- v11 §6 との吹き出し文言の一致
- フレーム丸ごと切り替えの原則遵守（§8）
- Retina 対応の正確性
- BubbleWindow のメモリリーク・タイマーリーク
- AppDelegate Coordinator の結線完全性
- テストカバレッジ

---

## 既存テスト分類（141 件）

| テストクラス | 件数 | 変更 |
|-------------|------|------|
| EventParserTests | 18 | なし |
| EventDeduplicatorTests | 7 | なし |
| HookServerUnitTests | 20 | なし |
| HookServerIntegrationTests | 21 | なし |
| HookServerAppDelegateTests | 3 | なし |
| LineBufferedEventDecoderTests | 11 | なし |
| StateMachineTests | 28 | なし |
| GazeControllerTests | 23 | なし |
| BlinkControllerTests | 6 | なし |
| AppDelegateCoordinatorTests | 4 | +5 件追加 |
| **合計** | **141** | **+19 = 160** |

---

## 完了基準

- [ ] ClabotchEyeView 実装（frame 01-08 描画、sleeping 常時閉じ目含む）
- [ ] BubbleWindow 実装
- [ ] AppDelegate 結線変更（ClabotchEyeView 埋め込み + BubbleWindow 結線）
- [ ] ClabotchEyeViewTests 10 件作成
- [ ] BubbleWindowTests 4 件作成
- [ ] AppDelegateCoordinatorTests 5 件追加
- [ ] 全 160 テスト合格
- [ ] Codex 実装レビュー A 取得
