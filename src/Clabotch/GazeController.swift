import Foundation
import os.log

/// 視線追跡コントローラー。main thread 専用。
/// v11 §11.5 準拠。AX API / NSWorkspace は DI 注入でテスト可能。
///
/// 視線はイベント駆動の「注意（attention）」モデルで制御する:
/// - フェーズ変更やターミナルのフロント遷移で一時的に注視を開始
/// - 注視期限が切れると neutral position (f01_center) に戻る
/// - stateOverride（idle/done/error/sleeping）は最優先
final class GazeController {

    // MARK: - 公開状態

    private(set) var mode: GazeMode = .fixed(.f02_rightDown, reason: .terminalNotFound)
    private(set) var gazeFrame: GazeFrame = .f02_rightDown
    private(set) var permissionStatus: GazePermissionStatus = .notDetermined

    // MARK: - Callback

    /// gazeFrame が変更されたときに呼ばれる。描画層が購読する。
    var onGazeFrameChanged: ((GazeFrame) -> Void)?

    // MARK: - 外部依存の注入

    /// メニューバーアイコンの中心座標を返す。AppDelegate が設定する。
    var statusItemCenterProvider: (() -> CGPoint?)?

    // MARK: - Properties

    private let axProvider: AXProvider
    private let workspaceProvider: WorkspaceProvider
    private let eventMonitor: GlobalEventMonitorProviding
    private let pollInterval: TimeInterval
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

    // MARK: - UserDefaults キー

    private enum PermissionKeys {
        static let didRequestAccessibility = "didRequestAccessibility"
    }

    // MARK: - Init

    init(
        axProvider: AXProvider = RealAXProvider(),
        workspaceProvider: WorkspaceProvider = RealWorkspaceProvider(),
        eventMonitor: GlobalEventMonitorProviding = RealGlobalEventMonitor(),
        pollInterval: TimeInterval = 0.5,
        attentionDuration: TimeInterval = 2.0,
        now: @escaping () -> Date = { Date() }
    ) {
        self.axProvider = axProvider
        self.workspaceProvider = workspaceProvider
        self.eventMonitor = eventMonitor
        self.pollInterval = pollInterval
        self.attentionDuration = attentionDuration
        self.now = now
    }

    // MARK: - Public API

    /// マスコット状態によるフレーム固定（最高優先度）。
    /// AppDelegate が onPhaseChanged を受けて呼ぶ。
    func setOverride(_ override: GazeOverride) {
        dispatchPrecondition(condition: .onQueue(.main))
        stateOverride = override
        if case .fixed(let frame, let reason) = override {
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

    /// ポーリング開始（0.5秒間隔）+ グローバルクリック監視開始。
    func startPolling() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard pollTimer == nil else { return }
        let timer = Timer.scheduledTimer(
            withTimeInterval: pollInterval, repeats: true
        ) { [weak self] _ in
            self?.update()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

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

    /// AX 権限のリクエスト（初回起動時）。
    func requestPermissionIfNeeded(completion: @escaping (GazePermissionStatus) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        checkPermission()
        guard permissionStatus == .notDetermined else {
            completion(permissionStatus)
            return
        }

        UserDefaults.standard.set(true, forKey: PermissionKeys.didRequestAccessibility)
        axProvider.requestTrust(prompt: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.checkPermission()
            completion(self?.permissionStatus ?? .denied)
        }
    }

    // MARK: - Private

    /// グローバルクリック検出時の処理。フロントアプリが対応ターミナルなら attention を開始する。
    private func handleGlobalClick() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let bundle = workspaceProvider.frontmostBundleIdentifier(),
              supportedBundles.contains(bundle) else { return }
        attentionExpiry = now().addingTimeInterval(attentionDuration)
        update()
    }

    private func update() {
        // v8: mascotStateOverride が最優先
        if case .fixed(let frame, let reason) = stateOverride {
            applyGaze(.fixed(frame, reason: reason), frame: frame)
            return
        }

        checkPermission()

        guard permissionStatus == .granted else {
            let reason: FixedGazeReason = (permissionStatus == .notDetermined)
                ? .permissionNotDetermined : .permissionDenied
            applyGaze(.fixed(.f02_rightDown, reason: reason), frame: .f02_rightDown)
            return
        }

        // フロントアプリの bundleID を取得
        let currentBundle = workspaceProvider.frontmostBundleIdentifier()

        // ターミナルがフロントに来たら注意を開始
        if currentBundle != lastFrontmostBundle {
            lastFrontmostBundle = currentBundle
            if let bundle = currentBundle, supportedBundles.contains(bundle) {
                attentionExpiry = now().addingTimeInterval(attentionDuration)
            }
        }

        // ① フロントアプリ分類
        if let reason = classifyFrontmostTerminal(bundleID: currentBundle) {
            let frame: GazeFrame = (reason == .unsupportedTerminal) ? .f02_rightDown : .f01_center
            applyGaze(.fixed(frame, reason: reason), frame: frame)
            return
        }

        // ② 注意が無効なら neutral position に戻る
        guard isAttentionActive else {
            applyGaze(.fixed(.f01_center, reason: .attentionNeutral), frame: .f01_center)
            return
        }

        // ③ AX でウィンドウ位置取得（注意が有効な間のみ）
        guard
            let pid = workspaceProvider.frontmostPID(),
            let origin = statusItemCenterProvider?()
        else { return }

        let (center, failReason) = axProvider.findTerminalCenter(pid: pid)
        if let reason = failReason {
            applyGaze(.fixed(.f01_center, reason: reason), frame: .f01_center)
            return
        }

        // ④ 量子化
        if let target = center {
            let frame = quantize(from: origin, to: target)
            applyGaze(.tracking, frame: frame)
        }
    }

    private func classifyFrontmostTerminal(bundleID: String?) -> FixedGazeReason? {
        guard let bundleID else {
            return .terminalNotFound
        }
        if tentativeBundles.contains(bundleID) { return .unsupportedTerminal }
        guard supportedBundles.contains(bundleID) else { return .terminalNotFound }
        return nil
    }

    private func quantize(from origin: CGPoint, to target: CGPoint) -> GazeFrame {
        let dx = target.x - origin.x
        let dy = -(target.y - origin.y)  // macOS 座標系: Y 軸下が正 → 反転
        switch (dx >= 0, dy >= 0) {
        case (true, false):  return .f02_rightDown
        case (false, false): return .f03_leftDown
        case (false, true):  return .f04_leftUp
        default:             return .f05_rightUp
        }
    }

    private func checkPermission() {
        let trusted = axProvider.isProcessTrusted()
        let didRequest = UserDefaults.standard.bool(forKey: PermissionKeys.didRequestAccessibility)

        if trusted { permissionStatus = .granted }
        else if didRequest { permissionStatus = .denied }
        else { permissionStatus = .notDetermined }
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
