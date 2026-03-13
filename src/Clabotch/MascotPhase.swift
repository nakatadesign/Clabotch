import Foundation

/// マスコットの表示状態。StateMachine の出力。
enum MascotPhase: Equatable {
    case idle
    case thinking
    case working(toolName: String)
    case done(elapsedMs: Int)
    case error(toolName: String, message: String?)
    case sleeping

    /// 表示優先度（§12.3 displayPriority）。値が小さいほど優先。
    var displayPriority: Int {
        switch self {
        case .error:    return 0
        case .working:  return 1
        case .thinking: return 2
        case .done:     return 3
        case .idle:     return 4
        case .sleeping: return 5
        }
    }
}

/// アクティブセッションの状態。StateMachine 内部で保持。
struct SessionState: Equatable {
    let sessionID: String
    var phase: MascotPhase
    let startedAt: Date
    var lastEventAt: Date
}
