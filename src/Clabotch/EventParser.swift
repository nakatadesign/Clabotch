import Foundation

/// NDJSON 行データを ClabotchEnvelope に変換する pure function。
/// 任意スレッドで呼び出し可能。不正な入力に対しては nil を返す。
struct EventParser {

    static func parse(_ data: Data) -> ClabotchEnvelope? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let schemaVersion = json["schema_version"] as? String,
            schemaVersion == "1",
            let eventIDRaw = json["event_id"] as? String,
            let eventID = UUID(uuidString: eventIDRaw),
            let event = json["event"] as? String,
            let sessionID = json["session_id"] as? String
        else { return nil }

        let parsed: ClabotchEvent
        switch event {
        case "session_start":
            parsed = .sessionStart(sessionID: sessionID)
        case "tool_start":
            guard let toolName = json["tool_name"] as? String else { return nil }
            parsed = .toolStart(sessionID: sessionID, toolName: toolName)
        case "tool_end":
            guard
                let toolName = json["tool_name"] as? String,
                let durationMs = json["duration_ms"] as? Int,
                let isError = json["is_error"] as? Bool
            else { return nil }
            parsed = .toolEnd(
                sessionID: sessionID, toolName: toolName,
                durationMs: durationMs, isError: isError,
                errorMessage: json["error_message"] as? String
            )
        case "session_done":
            parsed = .sessionDone(
                sessionID: sessionID,
                elapsedMs: json["elapsed_ms"] as? Int ?? 0
            )
        default:
            let rawJSON = String(data: data, encoding: .utf8) ?? ""
            parsed = .unknown(rawJSON: rawJSON)
        }

        return ClabotchEnvelope(eventID: eventID, event: parsed)
    }
}
