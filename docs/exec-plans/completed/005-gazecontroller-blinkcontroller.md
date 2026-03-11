# 実装計画 005: GazeController + BlinkController

## 概要

設計書 v11 §11.1-§11.6（Permission / Fallback Spec）、§6（マスコット状態一覧）に基づき、視線追跡（GazeController）とまばたき制御（BlinkController）を実装する。

StateMachine.onPhaseChanged → AppDelegate（Coordinator 役）→ GazeController.setOverride() の結線を行い、MascotPhase に応じた視線モード切替を実現する。

## 正典参照

- 設計書: `docs/design/current/clabotch_design_doc_v11.md`
- §6: マスコット状態一覧（L143-166）— phase ごとの視線・まばたき仕様
- §11.1: GazePermissionStatus（L629-641）
- §11.2: 権限判定ロジック（L643-670）
- §11.3: GazeMode / FixedGazeReason（L672-688）
- §11.4: 各シナリオの振る舞い仕様（L691-703）
- §11.5: GazeController v8 最終版（L705-892）
- §11.6: フォールバック優先順位（L895-905）

## 正典からの逸脱

| # | 内容 | v11 正典 | 本計画 | 理由 |
|---|------|---------|--------|------|
| 1 | AX API の DI 注入 | `AXIsProcessTrusted()` / `AXUIElement` 直接呼び出し | `AXProvider` protocol で抽象化し init 注入 | テスタビリティ（AX 権限なしの CI/テスト環境で動作検証可能にする） |
| 2 | NSWorkspace の DI 注入 | `NSWorkspace.shared.frontmostApplication` 直接使用 | `WorkspaceProvider` protocol で抽象化し init 注入。副作用: v11 では `frontmostApplication` 存在 + `bundleIdentifier` nil の場合 `bundleID = ""` となるが、本計画では `frontmostBundleIdentifier()` が nil を返す。挙動は同等（どちらも `.terminalNotFound`） | テスタビリティ（フロントアプリの切り替えをモックで検証） |
| 3 | pollTimer 間隔パラメータ化 | `0.5` 固定 | `init(pollInterval:)` でデフォルト 0.5 付き外部注入 | テスタビリティ（0.5秒待たずにポーリングを検証可能にする） |
| 4 | BlinkController のランダム間隔 DI | 2.8〜5.5秒の `Double.random(in:)` 直接使用 | `init(intervalRange:randomSource:)` で注入 | テスタビリティ（deterministic テスト） |
| 5 | BlinkController の phase 連動 | v11 §6 では「通常 / 停止」の記述のみ | `setBlinking(enabled:)` メソッドで AppDelegate から制御 | 責務の分離（BlinkController は phase を知らない。AppDelegate が onPhaseChanged を受けて制御） |
| 6 | onGazeFrameChanged コールバック | v11 §11.5 に存在しない | gazeFrame 変更時にコールバック通知を追加 | 描画層（計画 006）への通知インターフェースが必要。v11 は描画層の実装を含まないため未定義 |
| 7 | applyGaze() ヘルパーメソッド | v11 §11.5 では mode/gazeFrame を直接代入 | mode/gazeFrame 更新とコールバック通知を一元化するヘルパーメソッドを追加 | 変更検知と通知の漏れ防止。DRY 原則 |

## 前提条件

- [x] 計画 004 完了（StateMachine コア、Codex A）
- [x] 全 108 テスト合格（107 passed, 1 skipped）
- [x] StateMachine.onPhaseChanged コールバック実装済み
- [x] AppDelegate が StateMachine を所有し結線済み

## スコープ

**含む:**
- `GazeFrame` enum（5 方向）
- `GazePermissionStatus` enum
- `GazeMode` enum + `FixedGazeReason` enum
- `GazeOverride` enum
- `AXProvider` protocol + `RealAXProvider` / `MockAXProvider`
- `WorkspaceProvider` protocol + `RealWorkspaceProvider` / `MockWorkspaceProvider`
- `GazeController` class（v11 §11.5 準拠 + DI 注入）
- `BlinkController` class
- AppDelegate 結線（onPhaseChanged → setOverride + setBlinking）
- 全テスト

**含まない:**
- ClabotchEyeView / BubbleWindow（計画 006）
- フレーム描画（計画 006）
- Warp AX 属性ダンプ（別件）

---

## Step 1: 型定義

### 成果物

`src/Clabotch/GazeTypes.swift`

### 仕様

```swift
import Foundation

/// 視線フレーム。5方向。描画層が frame 番号に変換する。
enum GazeFrame: Equatable, CaseIterable {
    case f01_center       // 正面（error, sleeping, ターミナル未検出）
    case f02_rightDown    // 右下（idle, done, 権限未許可）
    case f03_leftDown     // 左下
    case f04_leftUp       // 左上
    case f05_rightUp      // 右上
}

/// AX 権限の状態。
enum GazePermissionStatus: Equatable {
    case notDetermined   // 未確認（初回起動）
    case granted         // 許可済み → フル視線追跡
    case denied          // 拒否済み → 固定視線 frame02
}

/// 固定視線の理由。
enum FixedGazeReason: Equatable {
    case permissionDenied
    case permissionNotDetermined
    case terminalNotFound
    case terminalInOtherSpace
    case terminalMinimized
    case unsupportedTerminal
    case mascotStateOverride
}

/// 視線モード。GazeController の出力。
enum GazeMode: Equatable {
    case tracking
    case fixed(GazeFrame, reason: FixedGazeReason)
}

/// StateMachine → GazeController 間のフェーズ連携型。
/// Coordinator（AppDelegate）が onPhaseChanged を受けて setOverride() に渡す。
enum GazeOverride: Equatable {
    case none
    case fixed(frame: GazeFrame, reason: FixedGazeReason)
}
```

### 設計根拠

- v11 §11.1-§11.3, §11.5 の定義をそのまま採用
- 全 enum は Equatable（自動合成可能）
- GazeOverride は StateMachine → GazeController の唯一のインターフェース
- GazeController は MascotPhase を一切知らない（責務の分離）

---

## Step 2: AXProvider / WorkspaceProvider プロトコル

### 成果物

`src/Clabotch/AXProvider.swift`

### 仕様

```swift
import AppKit

/// AX API の抽象化。テスト時に MockAXProvider を注入する。
protocol AXProvider {
    /// AXIsProcessTrusted() の抽象化
    func isProcessTrusted() -> Bool

    /// AXIsProcessTrustedWithOptions() の抽象化
    @discardableResult
    func requestTrust(prompt: Bool) -> Bool

    /// ターミナルウィンドウの中心座標を取得する。
    /// 成功: (CGPoint, nil)  失敗: (nil, FixedGazeReason)
    func findTerminalCenter(pid: pid_t) -> (CGPoint?, FixedGazeReason?)
}

/// NSWorkspace の抽象化。テスト時に MockWorkspaceProvider を注入する。
protocol WorkspaceProvider {
    /// フロントアプリの bundleIdentifier を返す。nil ならアプリ未検出。
    func frontmostBundleIdentifier() -> String?

    /// フロントアプリの PID を返す。nil ならアプリ未検出。
    func frontmostPID() -> pid_t?
}

// MARK: - 本番実装

struct RealAXProvider: AXProvider {
    func isProcessTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    func requestTrust(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func findTerminalCenter(pid: pid_t) -> (CGPoint?, FixedGazeReason?) {
        let axApp = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
            let windows = ref as? [AXUIElement], !windows.isEmpty
        else { return (nil, .terminalMinimized) }

        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(windows[0], kAXPositionAttribute as CFString, &posRef) == .success,
            AXUIElementCopyAttributeValue(windows[0], kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return (nil, .terminalInOtherSpace) }

        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return (CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2), nil)
    }
}

struct RealWorkspaceProvider: WorkspaceProvider {
    func frontmostBundleIdentifier() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    func frontmostPID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
}
```

### 設計根拠

- v11 §11.5 の `classifyFrontmostTerminal()` と `findTerminalCenter(pid:)` を AXProvider / WorkspaceProvider に分離
- GazeController のテストで AX 権限不要（MockAXProvider で代替）
- RealAXProvider は v11 §11.5 のコードをそのまま移植

---

## Step 3: GazeController 実装

### 成果物

`src/Clabotch/GazeController.swift`

### 仕様

```swift
import Foundation
import os.log

/// 視線追跡コントローラー。main thread 専用。
/// v11 §11.5 準拠。AX API / NSWorkspace は DI 注入でテスト可能。
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
    private let pollInterval: TimeInterval
    private var pollTimer: Timer?

    /// v8: mascotStateOverride
    private var stateOverride: GazeOverride = .none

    /// MVP: 確認済み対応ターミナル
    private let supportedBundles: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "org.wezfurlong.wezterm"
    ]

    /// AX 属性ダンプ確認後に supportedBundles へ昇格させる候補
    private let tentativeBundles: Set<String> = [
        "dev.warp.desktop"
    ]

    // MARK: - UserDefaults キー

    private enum PermissionKeys {
        static let didRequestAccessibility = "didRequestAccessibility"
    }

    // MARK: - Init

    init(
        axProvider: AXProvider = RealAXProvider(),
        workspaceProvider: WorkspaceProvider = RealWorkspaceProvider(),
        pollInterval: TimeInterval = 0.5
    ) {
        self.axProvider = axProvider
        self.workspaceProvider = workspaceProvider
        self.pollInterval = pollInterval
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

    /// ポーリング開始（0.5秒間隔）。
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
    }

    /// ポーリング停止。
    func stopPolling() {
        dispatchPrecondition(condition: .onQueue(.main))
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// AX 権限のリクエスト（初回起動時）。
    func requestPermissionIfNeeded(completion: @escaping (GazePermissionStatus) -> Void) {
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

        // ① フロントアプリ分類
        if let reason = classifyFrontmostTerminal() {
            let frame: GazeFrame = (reason == .unsupportedTerminal) ? .f02_rightDown : .f01_center
            applyGaze(.fixed(frame, reason: reason), frame: frame)
            return
        }

        // ② AX でウィンドウ位置取得
        guard
            let pid = workspaceProvider.frontmostPID(),
            let origin = statusItemCenterProvider?()
        else { return }

        let (center, failReason) = axProvider.findTerminalCenter(pid: pid)
        if let reason = failReason {
            applyGaze(.fixed(.f01_center, reason: reason), frame: .f01_center)
            return
        }

        // ③ 量子化
        if let target = center {
            let frame = quantize(from: origin, to: target)
            applyGaze(.tracking, frame: frame)
        }
    }

    private func classifyFrontmostTerminal() -> FixedGazeReason? {
        guard let bundleID = workspaceProvider.frontmostBundleIdentifier() else {
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
```

### 設計根拠

- v11 §11.5 のコードを忠実に移植
- AXProvider / WorkspaceProvider の DI 注入でテスト可能に（逸脱 #1, #2）
- `applyGaze()` は v11 にない追加メソッド。mode/gazeFrame の更新とコールバック通知を一元化し、変更があった場合のみ通知する
- `onGazeFrameChanged` コールバックは v11 にない追加。描画層（計画 006）が購読する
- `dispatchPrecondition` は計画 004 の方針を踏襲

---

## Step 4: BlinkController 実装

### 成果物

`src/Clabotch/BlinkController.swift`

### 仕様

```swift
import Foundation
import os.log

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
```

### 設計根拠

- v11 §6 の「通常 / 停止」をそのまま実装
- `setBlinking(enabled:)` により AppDelegate が phase に応じて制御（逸脱 #5）
- BlinkController は MascotPhase を一切知らない（GazeController と同様の責務分離）
- `randomSource` の DI でテスト時に deterministic な間隔を再現可能（逸脱 #4）
- `onBlink` コールバックは描画層（計画 006）が購読する

---

## Step 5: AppDelegate 結線変更

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // メニューバーに「C」を表示
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "C"

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

        // GazeController コールバック
        gazeController.onGazeFrameChanged = { frame in
            os_log(.info, "視線フレーム変更: %{public}@", String(describing: frame))
        }

        // BlinkController コールバック
        blinkController.onBlink = {
            os_log(.info, "まばたき発生")
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
        }
        stateMachine.onEphemeralDone = { elapsedMs in
            os_log(.info, "ephemeral done: %d ms", elapsedMs)
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
            stateMachine.start()          // ① 初期フェーズ emit → setOverride / setBlinking
            gazeController.startPolling() // ② polling 開始
        } catch let error as HookServerError where error == .alreadyRunning {
            os_log(.error, "既に別インスタンスが起動中")
            NSApplication.shared.terminate(nil)
        } catch {
            os_log(.error, "HookServer failed to start: %{public}@", error.localizedDescription)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
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
        case .idle:
            return .fixed(frame: .f02_rightDown, reason: .mascotStateOverride)
        case .thinking:
            return .none
        case .working:
            return .none
        case .done:
            return .fixed(frame: .f02_rightDown, reason: .mascotStateOverride)
        case .error:
            return .fixed(frame: .f01_center, reason: .mascotStateOverride)
        case .sleeping:
            return .fixed(frame: .f01_center, reason: .mascotStateOverride)
        }
    }

    // MARK: - Phase → Blink 変換（v11 §6 準拠）

    static func isBlinkEnabled(for phase: MascotPhase) -> Bool {
        switch phase {
        case .idle, .thinking, .working, .done:
            return true
        case .error, .sleeping:
            return false
        }
    }
}
```

### 設計根拠

- v11 §11.5 の「Coordinator / AppDelegate が onPhaseChanged を受けて setOverride() を呼ぶ」をそのまま実装
- `gazeOverride(for:)` / `isBlinkEnabled(for:)` を static メソッドにしてテスト可能に
- 初期化順序: `stateMachine.start()` → `gazeController.startPolling()`（v11 §12.2 の doc comment 準拠）
- `applicationWillTerminate` で `gazeController.stopPolling()` を追加

---

## Step 6: テスト

### 成果物

- `src/ClabotchTests/GazeControllerTests.swift`
- `src/ClabotchTests/BlinkControllerTests.swift`
- `src/ClabotchTests/MockProviders.swift`

### MockProviders

```swift
// MockAXProvider: isProcessTrusted / requestTrust / findTerminalCenter をモック
// MockWorkspaceProvider: frontmostBundleIdentifier / frontmostPID をモック
```

### GazeControllerTests（23 件）

#### 6a. Override テスト（4 件）

| # | テスト名 | 検証内容 |
|---|---------|---------|
| 1 | `testSetOverrideFixedChangesMode` | `.fixed(.f01_center, .mascotStateOverride)` → mode/gazeFrame 更新 |
| 2 | `testSetOverrideNoneAllowsUpdate` | `.none` 設定後に update() で再計算される |
| 3 | `testOverridePriorityOverPermission` | override 設定中は permission denied でも override が優先 |
| 4 | `testOnGazeFrameChangedCallback` | gazeFrame 変更時にコールバック発火、同一 frame では発火しない |

#### 6b. Permission テスト（7 件）

| # | テスト名 | 検証内容 |
|---|---------|---------|
| 5 | `testPermissionNotDetermined` | isProcessTrusted=false, didRequest=false → .notDetermined |
| 6 | `testPermissionGranted` | isProcessTrusted=true → .granted |
| 7 | `testPermissionDenied` | isProcessTrusted=false, didRequest=true → .denied |
| 8 | `testPermissionDeniedFixedF02` | denied → mode == .fixed(.f02_rightDown, .permissionDenied) |
| 9 | `testRequestPermissionCallsRequestTrust` | notDetermined 時に requestPermissionIfNeeded → requestTrust(prompt: true) が呼ばれる |
| 10 | `testRequestPermissionSetsDidRequestFlag` | requestPermissionIfNeeded 後に UserDefaults.didRequestAccessibility == true |
| 11 | `testRequestPermissionCompletionCalled` | requestPermissionIfNeeded の completion が呼ばれ、status が返る |

#### 6c. Terminal 分類テスト（5 件）

| # | テスト名 | 検証内容 |
|---|---------|---------|
| 12 | `testSupportedTerminalTracking` | com.apple.Terminal → tracking モード |
| 13 | `testUnsupportedTerminalFixed` | dev.warp.desktop → .fixed(.f02_rightDown, .unsupportedTerminal) |
| 14 | `testNoFrontAppTerminalNotFound` | frontmostBundleIdentifier=nil → .fixed(.f01_center, .terminalNotFound) |
| 15 | `testNonTerminalAppNotFound` | com.apple.Safari → .fixed(.f01_center, .terminalNotFound) |
| 16 | `testTerminalMinimized` | windows 空配列 → .fixed(.f01_center, .terminalMinimized) |

#### 6d. 量子化テスト（4 件）

| # | テスト名 | 検証内容 |
|---|---------|---------|
| 17 | `testQuantizeRightDown` | target が origin の右下 → .f02_rightDown |
| 18 | `testQuantizeLeftDown` | target が origin の左下 → .f03_leftDown |
| 19 | `testQuantizeLeftUp` | target が origin の左上 → .f04_leftUp |
| 20 | `testQuantizeRightUp` | target が origin の右上 → .f05_rightUp |

#### 6e. Polling テスト（3 件）

| # | テスト名 | 検証内容 |
|---|---------|---------|
| 21 | `testStartPollingCreatesTimer` | startPolling() 後に poll が発火する |
| 22 | `testStopPollingInvalidatesTimer` | stopPolling() 後に poll が停止する |
| 23 | `testStartPollingIdempotent` | 2回呼んでもタイマーは1つのみ |

### BlinkControllerTests（6 件）

| # | テスト名 | 検証内容 |
|---|---------|---------|
| 24 | `testSetBlinkingEnabledStartsTimer` | setBlinking(enabled: true) → onBlink が呼ばれる |
| 25 | `testSetBlinkingDisabledStopsTimer` | setBlinking(enabled: false) → onBlink が呼ばれなくなる |
| 26 | `testBlinkIntervalInRange` | 発火間隔が intervalRange 内 |
| 27 | `testDeterministicRandomSource` | 固定 randomSource → 予測可能な間隔 |
| 28 | `testSetBlinkingIdempotent` | true を2回呼んでもタイマーがリセットされ1つのみ維持される |
| 29 | `testSetBlinkingDisabledIsBlinkingFalse` | disabled 後に isBlinking == false |

### AppDelegate 変換テスト（4 件）

`src/ClabotchTests/AppDelegateCoordinatorTests.swift`

| # | テスト名 | 検証内容 |
|---|---------|---------|
| 30 | `testGazeOverrideForIdleFixed` | idle → .fixed(.f02_rightDown, .mascotStateOverride) |
| 31 | `testGazeOverrideForThinkingNone` | thinking → .none |
| 32 | `testGazeOverrideForErrorFixed` | error → .fixed(.f01_center, .mascotStateOverride) |
| 33 | `testIsBlinkEnabledMapping` | idle/thinking/working/done → true, error/sleeping → false |

### テスト合計

- GazeControllerTests: 23 件
- BlinkControllerTests: 6 件
- AppDelegateCoordinatorTests: 4 件
- 既存テスト: 108 件（107 passed, 1 skipped）
- **目標合計: 141 件（140 passed, 1 skipped）**

### テスト設計方針

1. **AX API モック**: MockAXProvider / MockWorkspaceProvider で全 AX 呼び出しを代替。テスト環境に AX 権限不要
2. **Timer テスト**: pollInterval / intervalRange を短い値（0.05〜0.1秒）に設定し、XCTestExpectation で検証
3. **UserDefaults 隔離**: テストケースごとに `UserDefaults.standard.removeObject(forKey:)` で `didRequestAccessibility` をリセット
4. **量子化テスト**: statusItemCenterProvider を固定座標、MockAXProvider.findTerminalCenter を固定座標にして deterministic 検証
5. **main thread 保証**: 全テストを `@MainActor` で実行

---

## Step 7: xcodegen + ビルド + テスト実行

```bash
cd src && xcodegen generate && xcodebuild test -project Clabotch.xcodeproj -scheme Clabotch -destination 'platform=macOS'
```

目標: 141 テスト全通過（140 passed, 1 skipped）

---

## Step 8: Codex 実装レビュー

レビュー観点:
- v11 §11.5 との整合性
- フォールバック優先順位の正確性（§11.6）
- AXProvider / WorkspaceProvider の DI 設計の妥当性
- 量子化ロジックの正確性
- BlinkController の phase 連動の正確性
- AppDelegate Coordinator の結線完全性
- テストカバレッジ

---

## 既存テスト分類（108 件）

| テストクラス | 件数 | 変更 |
|-------------|------|------|
| EventParserTests | 18 | なし |
| EventDeduplicatorTests | 7 | なし |
| HookServerUnitTests | 20 | なし |
| HookServerIntegrationTests | 21 | なし |
| HookServerAppDelegateTests | 3 | なし |
| LineBufferedEventDecoderTests | 11 | なし |
| StateMachineTests | 28 | なし |
| **合計** | **108** | |

---

## 完了基準

- [ ] GazeFrame / GazePermissionStatus / GazeMode / FixedGazeReason / GazeOverride 型定義
- [ ] AXProvider / WorkspaceProvider protocol + Real/Mock 実装
- [ ] GazeController 実装（全メソッド）
- [ ] BlinkController 実装
- [ ] AppDelegate 結線（onPhaseChanged → setOverride + setBlinking）
- [ ] GazeControllerTests 23 件作成
- [ ] BlinkControllerTests 6 件作成
- [ ] AppDelegateCoordinatorTests 4 件作成
- [ ] 全 141 テスト合格
- [ ] Codex 実装レビュー A 取得
