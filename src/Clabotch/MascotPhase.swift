import Foundation

/// マスコットの表示状態。StateMachine の出力。
enum MascotPhase: Equatable {
    case idle
    case thinking
    case working(toolName: String)
    case done(elapsedMs: Int)
    case error(toolName: String, message: String?)
    case sleeping
}

/// アクティブセッションの状態。StateMachine 内部で保持。
struct SessionState: Equatable {
    let sessionID: String
    var phase: MascotPhase
    let startedAt: Date
    var lastEventAt: Date
}
