import Foundation

/// 視線フレーム。7方向。描画層が frame 番号に変換する。
enum GazeFrame: Equatable, CaseIterable {
    case f01_center       // 正面（error, sleeping, ターミナル未検出）
    case f02_rightDown    // 右下（idle, done, 権限未許可）
    case f03_leftDown     // 左下
    case f04_leftUp       // 左上
    case f05_rightUp      // 右上
    case f06_right        // 右（水平）
    case f07_left         // 左（水平）
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
    case attentionNeutral
}

/// 視線モード。GazeController の出力。
enum GazeMode: Equatable {
    case tracking
    case fixed(GazeFrame, reason: FixedGazeReason)
}

/// StateMachine → GazeController 間のフェーズ連携型。
/// Coordinator（AppDelegate）が onPhaseChanged を受けて setOverride() に渡す。
///
/// `allowsAttentionOverride`: true の場合、attention 中はこの override をバイパスして
/// ターミナル追跡を許可する。idle/done で true、error/sleeping で false。
enum GazeOverride: Equatable {
    case none
    case fixed(frame: GazeFrame, reason: FixedGazeReason, allowsAttentionOverride: Bool = false)
}

/// グローバルイベントモニターの抽象化。テスト時にモック差し替え可能にする。
protocol GlobalEventMonitorProviding: AnyObject {
    /// グローバルマウスクリックを監視開始する。handler はクリック検出時に呼ばれる。
    func startMonitoring(handler: @escaping () -> Void)
    /// 監視を停止する。
    func stopMonitoring()
}
