import Foundation

/// hook スクリプトから受信するイベント型。
/// unknown は将来の拡張に備えた forward-compatible ケース。
enum ClabotchEvent: Equatable {
    case sessionStart(sessionID: String)
    case toolStart(sessionID: String, toolName: String)
    case toolEnd(sessionID: String, toolName: String,
                 durationMs: Int, isError: Bool, errorMessage: String?)
    case sessionDone(sessionID: String, elapsedMs: Int)
    case unknown(rawJSON: String)
}

/// EventParser.parse の戻り値。event_id によるデデュプリケーションの単位。
struct ClabotchEnvelope: Equatable {
    let eventID: UUID
    let event: ClabotchEvent
}
