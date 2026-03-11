import XCTest
@testable import Clabotch

// MARK: - EventParserTests（pure function テスト、required 15）

final class EventParserTests: XCTestCase {

    // MARK: - 正常系（5）

    // 1. session_start
    func testParseSessionStart() {
        let json = makeTestNDJSON(event: "session_start", sessionID: "ses-001")
        let data = Data(json.utf8)
        let envelope = EventParser.parse(data)
        XCTAssertNotNil(envelope)
        XCTAssertEqual(envelope?.event, .sessionStart(sessionID: "ses-001"))
    }

    // 2. tool_start
    func testParseToolStart() {
        let id = UUID()
        let json = """
        {"schema_version":"1","event_id":"\(id.uuidString)","event":"tool_start","session_id":"ses-002","tool_name":"Read"}
        """
        let envelope = EventParser.parse(Data(json.utf8))
        XCTAssertNotNil(envelope)
        XCTAssertEqual(envelope?.eventID, id)
        XCTAssertEqual(envelope?.event, .toolStart(sessionID: "ses-002", toolName: "Read"))
    }

    // 3. tool_end（エラーメッセージあり）
    func testParseToolEnd() {
        let id = UUID()
        let json = """
        {"schema_version":"1","event_id":"\(id.uuidString)","event":"tool_end","session_id":"ses-003","tool_name":"Bash","duration_ms":150,"is_error":true,"error_message":"タイムアウト"}
        """
        let envelope = EventParser.parse(Data(json.utf8))
        XCTAssertNotNil(envelope)
        XCTAssertEqual(envelope?.event, .toolEnd(
            sessionID: "ses-003", toolName: "Bash",
            durationMs: 150, isError: true, errorMessage: "タイムアウト"))
    }

    // 4. session_done
    func testParseSessionDone() {
        let id = UUID()
        let json = """
        {"schema_version":"1","event_id":"\(id.uuidString)","event":"session_done","session_id":"ses-004","elapsed_ms":5000}
        """
        let envelope = EventParser.parse(Data(json.utf8))
        XCTAssertNotNil(envelope)
        XCTAssertEqual(envelope?.event, .sessionDone(sessionID: "ses-004", elapsedMs: 5000))
    }

    // 5. session_done（elapsed_ms 省略 → デフォルト 0）
    func testParseSessionDoneDefaultElapsed() {
        let id = UUID()
        let json = """
        {"schema_version":"1","event_id":"\(id.uuidString)","event":"session_done","session_id":"ses-005"}
        """
        let envelope = EventParser.parse(Data(json.utf8))
        XCTAssertNotNil(envelope)
        XCTAssertEqual(envelope?.event, .sessionDone(sessionID: "ses-005", elapsedMs: 0))
    }

    // MARK: - エラー系（10）

    // 6. schema_version 欠落
    func testMissingSchemaVersion() {
        let json = """
        {"event_id":"\(UUID().uuidString)","event":"session_start","session_id":"s"}
        """
        XCTAssertNil(EventParser.parse(Data(json.utf8)))
    }

    // 7. schema_version 不一致
    func testWrongSchemaVersion() {
        let json = """
        {"schema_version":"2","event_id":"\(UUID().uuidString)","event":"session_start","session_id":"s"}
        """
        XCTAssertNil(EventParser.parse(Data(json.utf8)))
    }

    // 8. event_id 欠落
    func testMissingEventID() {
        let json = """
        {"schema_version":"1","event":"session_start","session_id":"s"}
        """
        XCTAssertNil(EventParser.parse(Data(json.utf8)))
    }

    // 9. event_id 不正（UUID でない文字列）
    func testInvalidEventID() {
        let json = """
        {"schema_version":"1","event_id":"not-a-uuid","event":"session_start","session_id":"s"}
        """
        XCTAssertNil(EventParser.parse(Data(json.utf8)))
    }

    // 10. event フィールド欠落
    func testMissingEvent() {
        let json = """
        {"schema_version":"1","event_id":"\(UUID().uuidString)","session_id":"s"}
        """
        XCTAssertNil(EventParser.parse(Data(json.utf8)))
    }

    // 11. session_id 欠落
    func testMissingSessionID() {
        let json = """
        {"schema_version":"1","event_id":"\(UUID().uuidString)","event":"session_start"}
        """
        XCTAssertNil(EventParser.parse(Data(json.utf8)))
    }

    // 12. tool_start で tool_name 欠落
    func testToolStartMissingToolName() {
        let json = """
        {"schema_version":"1","event_id":"\(UUID().uuidString)","event":"tool_start","session_id":"s"}
        """
        XCTAssertNil(EventParser.parse(Data(json.utf8)))
    }

    // 13. tool_end（error_message 省略 → nil）
    func testParseToolEndWithoutErrorMessage() {
        let id = UUID()
        let json = """
        {"schema_version":"1","event_id":"\(id.uuidString)","event":"tool_end","session_id":"s","tool_name":"Read","duration_ms":100,"is_error":false}
        """
        let envelope = EventParser.parse(Data(json.utf8))
        XCTAssertNotNil(envelope)
        XCTAssertEqual(envelope?.event, .toolEnd(
            sessionID: "s", toolName: "Read",
            durationMs: 100, isError: false, errorMessage: nil))
    }

    // 14. 不正バイト列（JSONSerialization がエラーを返す）
    func testInvalidJSON() {
        let data = Data([0xFF, 0xFE, 0x00])
        XCTAssertNil(EventParser.parse(data))
    }

    // 15. トップレベルが Array（Object でない）
    func testJSONArray() {
        let data = Data("[1,2,3]".utf8)
        XCTAssertNil(EventParser.parse(data))
    }

    // 16. tool_end で必須フィールド欠落（duration_ms なし）
    func testToolEndMissingDurationMs() {
        let json = """
        {"schema_version":"1","event_id":"\(UUID().uuidString)","event":"tool_end","session_id":"s","tool_name":"Read","is_error":false}
        """
        XCTAssertNil(EventParser.parse(Data(json.utf8)))
    }

    // MARK: - forward-compatible（2）

    // 14. 未知イベントは unknown(rawJSON:) として保持
    func testUnknownEventPreservesRawJSON() {
        let id = UUID()
        let json = """
        {"schema_version":"1","event_id":"\(id.uuidString)","event":"future_event","session_id":"s","extra":42}
        """
        let envelope = EventParser.parse(Data(json.utf8))
        XCTAssertNotNil(envelope)
        XCTAssertEqual(envelope?.eventID, id)
        if case .unknown(let rawJSON) = envelope?.event {
            XCTAssertTrue(rawJSON.contains("future_event"))
        } else {
            XCTFail("unknown ケースを期待: \(String(describing: envelope?.event))")
        }
    }

    // 15. 既知イベントに余分なフィールドがあっても無視して正常パース
    func testExtraFieldsIgnored() {
        let id = UUID()
        let json = """
        {"schema_version":"1","event_id":"\(id.uuidString)","event":"session_start","session_id":"ses-extra","bonus":"ignored"}
        """
        let envelope = EventParser.parse(Data(json.utf8))
        XCTAssertNotNil(envelope)
        XCTAssertEqual(envelope?.event, .sessionStart(sessionID: "ses-extra"))
    }
}
