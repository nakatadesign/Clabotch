import Foundation

/// マスコットの表示状態。StateMachine の出力。
enum MascotPhase: Equatable {
    case idle
    case thinking
    case responding
    case working(toolName: String)
    case done(elapsedMs: Int)
    case error(toolName: String, message: String?)
    case sleeping

    /// 表示優先度（§12.3 displayPriority）。値が小さいほど優先。
    var displayPriority: Int {
        switch self {
        case .error:      return 0
        case .working:    return 1
        case .responding: return 2
        case .thinking:   return 3
        case .done:       return 4
        case .idle:       return 5
        case .sleeping:   return 6
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
