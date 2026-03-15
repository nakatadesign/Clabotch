import AppKit
import os.log

/// 視線追跡コントローラー。main thread 専用。
/// v11 §11.5 準拠。AX API / NSWorkspace は DI 注入でテスト可能。
///
/// 視線はイベント駆動の「注意（attention）」モデルで制御する:
/// - フェーズ変更やターミナルのフロント遷移・クリックで一時的に注視を開始
/// - 注視期限が切れると neutral position (f01_center) に戻る
/// - error/sleeping の stateOverride は最優先（attention でもバイパスしない）
/// - idle/done の stateOverride は attention 中にバイパスされる
final class GazeController {

    // MARK: - 公開状態

    private(set) var mode: GazeMode = .fixed(.f03_leftDown, reason: .terminalNotFound)
    private(set) var gazeFrame: GazeFrame = .f03_leftDown
    private(set) var permissionStatus: GazePermissionStatus = .notGranted

    // MARK: - Callback

    /// gazeFrame が変更されたときに呼ばれる。描画層が購読する。
    var onGazeFrameChanged: ((GazeFrame) -> Void)?

    /// AX 権限状態が変化したときに呼ばれる。
    var onPermissionChanged: ((GazePermissionStatus) -> Void)?

    /// ターミナルウィンドウがクリックされたときに呼ばれる。
    var onTerminalClicked: (() -> Void)?

    // MARK: - 外部依存の注入

    /// メニューバーアイコンの中心座標を返す。AppDelegate が設定する。
    var statusItemCenterProvider: (() -> CGPoint?)?

    // MARK: - Properties

    private let axProvider: AXProvider
    private let workspaceProvider: WorkspaceProvider
    private let eventMonitor: GlobalEventMonitorProviding
    private let pollIntervalGranted: TimeInterval
    private let pollIntervalNotGranted: TimeInterval
    private var currentPollInterval: TimeInterval
    private var pollTimer: Timer?
    private let now: () -> Date

    /// v8: mascotStateOverride
    private var stateOverride: GazeOverride = .none

    /// 注意（attention）: 一時注視の有効期限
    private var attentionExpiry: Date?

    /// 注意の持続時間（秒）
    private let attentionDuration: TimeInterval

    /// 前回ポーリング時のフロントアプリ bundleID（アプリ切替検出用）
    private var lastFrontmostBundle: String?

    /// MVP: 確認済み対応ターミナル
    private let supportedBundles: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "org.wezfurlong.wezterm",
        "dev.warp.Warp-Stable"
    ]

    /// AX 属性ダンプ確認後に supportedBundles へ昇格させる候補
    /// Warp は計画 009 で AX 属性ダンプ検証済み → supportedBundles に昇格済み
    private let tentativeBundles: Set<String> = []

    // MARK: - Init

    init(
        axProvider: AXProvider = RealAXProvider(),
        workspaceProvider: WorkspaceProvider = RealWorkspaceProvider(),
        eventMonitor: GlobalEventMonitorProviding = RealGlobalEventMonitor(),
        pollInterval: TimeInterval = 0.5,
        pollIntervalNotGranted: TimeInterval = 2.0,
        attentionDuration: TimeInterval = 2.0,
        now: @escaping () -> Date = { Date() }
    ) {
        self.axProvider = axProvider
        self.workspaceProvider = workspaceProvider
        self.eventMonitor = eventMonitor
        self.pollIntervalGranted = pollInterval
        self.pollIntervalNotGranted = pollIntervalNotGranted
        self.currentPollInterval = pollInterval
        self.attentionDuration = attentionDuration
        self.now = now
    }

    // MARK: - Public API

    /// マスコット状態によるフレーム固定（最高優先度）。
    /// AppDelegate が onPhaseChanged を受けて呼ぶ。
    func setOverride(_ override: GazeOverride) {
        dispatchPrecondition(condition: .onQueue(.main))
        stateOverride = override
        if case .fixed(let frame, let reason, _) = override {
            applyGaze(.fixed(frame, reason: reason), frame: frame)
        }
        // .none の場合は次の update() で再計算
    }

    /// ターミナルウィンドウ方向へ一時的に注視を開始する。
    /// CoordinatorBinder がフェーズ変更時に呼ぶ。
    func lookAtTerminal(duration: TimeInterval? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        let d = duration ?? attentionDuration
        attentionExpiry = now().addingTimeInterval(d)
        // 即座に視線を更新（次のポーリングを待たない）
        update()
    }

    /// 注意（attention）が有効か
    var isAttentionActive: Bool {
        guard let expiry = attentionExpiry else { return false }
        return now() < expiry
    }

    /// ポーリング開始 + グローバルクリック監視開始。
    /// 権限状態に応じて間隔を切替（granted: 0.5s, notGranted: 2.0s）。
    func startPolling() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard pollTimer == nil else { return }
        recreateTimer()

        // ターミナルウィンドウへのクリックで注意を再開する
        // NSEvent.addGlobalMonitorForEvents のコールバックはメインスレッドで呼ばれる
        eventMonitor.startMonitoring { [weak self] in
            self?.handleGlobalClick()
        }
    }

    /// ポーリング停止 + クリック監視停止。
    func stopPolling() {
        dispatchPrecondition(condition: .onQueue(.main))
        pollTimer?.invalidate()
        pollTimer = nil
        eventMonitor.stopMonitoring()
    }

    /// ポーリングタイマーを現在の間隔で再作成する。
    private func recreateTimer() {
        pollTimer?.invalidate()
        let timer = Timer.scheduledTimer(
            withTimeInterval: currentPollInterval, repeats: true
        ) { [weak self] _ in
            self?.update()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// 権限状態に応じてポーリング間隔を調整する。
    private func adjustPollInterval() {
        let newInterval = (permissionStatus == .granted)
            ? pollIntervalGranted : pollIntervalNotGranted
        guard newInterval != currentPollInterval, pollTimer != nil else { return }
        currentPollInterval = newInterval
        recreateTimer()
        os_log(.default, "👁 Gaze: ポーリング間隔変更 → %.1f秒", newInterval)
    }

    /// AX 権限のリクエスト。macOS のシステムダイアログを表示する。
    /// 権限の結果はポーリングで自動検知されるため、completion は即座に呼ばれる。
    func requestPermission() {
        dispatchPrecondition(condition: .onQueue(.main))
        axProvider.requestTrust(prompt: true)
    }

    // MARK: - Private

    /// グローバルクリック検出時の処理。フロントアプリが対応ターミナルなら attention を開始する。
    private func handleGlobalClick() {
        dispatchPrecondition(condition: .onQueue(.main))
        let bundle = workspaceProvider.frontmostBundleIdentifier()
        os_log(.info, "[Gaze] クリック検出: bundle=%{public}@", bundle ?? "nil")
        guard let bundle, supportedBundles.contains(bundle) else {
            os_log(.info, "[Gaze] クリック無視: 対応ターミナルではない")
            return
        }
        os_log(.info, "[Gaze] attention 開始: %{public}@", bundle)
        attentionExpiry = now().addingTimeInterval(attentionDuration)
        onTerminalClicked?()
        update()
    }

    private func update() {
        // アプリ切替検出は常に実行（override/permission チェック前）
        let currentBundle = workspaceProvider.frontmostBundleIdentifier()
        if currentBundle != lastFrontmostBundle {
            lastFrontmostBundle = currentBundle
            if let bundle = currentBundle, supportedBundles.contains(bundle) {
                os_log(.default, "👁 Gaze: アプリ切替検出: %{public}@ → attention 開始", bundle)
                attentionExpiry = now().addingTimeInterval(attentionDuration)
            }
        }

        // stateOverride チェック
        // allowsAttentionOverride=false（error/sleeping）は常に最優先
        if case .fixed(let frame, let reason, let allowsAttention) = stateOverride {
            if !allowsAttention {
                applyGaze(.fixed(frame, reason: reason), frame: frame)
                return
            }
            // allowsAttentionOverride=true の場合は常にバイパス（attention 不要）
        }

        checkPermission()

        guard permissionStatus == .granted else {
            os_log(.default, "👁 Gaze: 権限なし → f03_leftDown")
            applyGaze(.fixed(.f03_leftDown, reason: .permissionNotGranted), frame: .f03_leftDown)
            return
        }

        // ① AX でウィンドウ位置取得
        guard
            let pid = workspaceProvider.frontmostPID(),
            let origin = statusItemCenterProvider?()
        else { return }

        let (center, failReason) = axProvider.findTerminalCenter(pid: pid)
        if let reason = failReason {
            applyGaze(.fixed(.f01_center, reason: reason), frame: .f01_center)
            return
        }

        // ② 量子化
        if let target = center {
            let frame = quantize(from: origin, to: target)
            os_log(.default, "👁 Gaze: origin=(%.0f,%.0f) target=(%.0f,%.0f) dx=%.0f dy=%.0f → %{public}@",
                   origin.x, origin.y, target.x, target.y,
                   target.x - origin.x, target.y - origin.y,
                   String(describing: frame))
            applyGaze(.tracking, frame: frame)
        }
    }

    private func quantize(from origin: CGPoint, to target: CGPoint) -> GazeFrame {
        let screen = NSScreen.screens.first ?? NSScreen.main
        let screenWidth = screen?.frame.width ?? 1440
        let screenThresholdX = screenWidth * 0.6

        // 左右判定のみ: 画面左から60%を超えたら右下、それ以外は左下
        let isRight = target.x >= screenThresholdX
        return isRight ? .f02_rightDown : .f03_leftDown
    }

    private func checkPermission() {
        let trusted = axProvider.isProcessTrusted()
        let oldStatus = permissionStatus
        permissionStatus = trusted ? .granted : .notGranted

        // 間隔調整は変化時以外でも不一致なら実行（起動直後の初回 poll 対策）
        adjustPollInterval()

        if permissionStatus != oldStatus {
            os_log(.default, "👁 Gaze: 権限変化: %{public}@ → %{public}@",
                   String(describing: oldStatus), String(describing: permissionStatus))
            onPermissionChanged?(permissionStatus)
        }
    }

    /// mode / gazeFrame を更新し、変更があれば onGazeFrameChanged を呼ぶ。
    private func applyGaze(_ newMode: GazeMode, frame newFrame: GazeFrame) {
        let changed = gazeFrame != newFrame
        mode = newMode
        gazeFrame = newFrame
        if changed {
            onGazeFrameChanged?(newFrame)
        }
    }
}
