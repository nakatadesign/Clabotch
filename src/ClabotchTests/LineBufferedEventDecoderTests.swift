import XCTest
@testable import Clabotch

final class LineBufferedEventDecoderTests: XCTestCase {

    func testSingleCompleteLine() {
        let decoder = LineBufferedEventDecoder()
        let lines = decoder.append(Data("{\"event\":\"test\"}\n".utf8))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(String(data: lines[0], encoding: .utf8), "{\"event\":\"test\"}")
    }

    func testMultipleLines() {
        let decoder = LineBufferedEventDecoder()
        let lines = decoder.append(Data("line1\nline2\n".utf8))
        XCTAssertEqual(lines.count, 2)
    }

    func testPartialLine() {
        let decoder = LineBufferedEventDecoder()
        let lines1 = decoder.append(Data("{\"event\":\"te".utf8))
        XCTAssertEqual(lines1.count, 0)
        let lines2 = decoder.append(Data("st\"}\n".utf8))
        XCTAssertEqual(lines2.count, 1)
    }

    func testEmptyLineSkip() {
        let decoder = LineBufferedEventDecoder()
        let lines = decoder.append(Data("\n\n{\"event\":\"x\"}\n".utf8))
        XCTAssertEqual(lines.count, 1)
    }

    func testExactly8KB() {
        let decoder = LineBufferedEventDecoder()
        let payload = String(repeating: "a", count: 8192)
        let lines = decoder.append(Data((payload + "\n").utf8))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].count, 8192)
    }

    func testOversizeLine() {
        let decoder = LineBufferedEventDecoder()
        let payload = String(repeating: "a", count: 8193)
        let lines = decoder.append(Data((payload + "\n").utf8))
        XCTAssertEqual(lines.count, 0)
        XCTAssertEqual(decoder.droppedLineCount, 1)
    }

    func testOversizeSecondHalfNotRevived() {
        let decoder = LineBufferedEventDecoder()
        // 改行なしで 8KB 超を送信 → dropping フラグ ON
        let oversizeChunk = String(repeating: "x", count: 9000)
        _ = decoder.append(Data(oversizeChunk.utf8))
        // 次の改行で後半が行として復活しないこと
        let lines = decoder.append(Data("remainder\n".utf8))
        XCTAssertEqual(lines.count, 0)
        XCTAssertEqual(decoder.droppedLineCount, 1)
    }

    func testRecoveryAfterOversize() {
        let decoder = LineBufferedEventDecoder()
        let oversizeChunk = String(repeating: "x", count: 9000)
        _ = decoder.append(Data(oversizeChunk.utf8))
        // dropping の後半を消化
        _ = decoder.append(Data("\n".utf8))
        // 正常行が処理されること
        let lines = decoder.append(Data("normal\n".utf8))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(String(data: lines[0], encoding: .utf8), "normal")
    }

    func testMultipleLinesWithTrailingPartial() {
        let decoder = LineBufferedEventDecoder()
        let lines = decoder.append(Data("line1\nline2\npartial".utf8))
        XCTAssertEqual(lines.count, 2)
        // partial はバッファに残る
        let lines2 = decoder.append(Data("\n".utf8))
        XCTAssertEqual(lines2.count, 1)
        XCTAssertEqual(String(data: lines2[0], encoding: .utf8), "partial")
    }

    func testLargeChunkRecovery() {
        let decoder = LineBufferedEventDecoder()
        // 1MB chunk（改行なし）
        let megaChunk = String(repeating: "z", count: 1_000_000)
        _ = decoder.append(Data(megaChunk.utf8))
        // dropping 消化
        _ = decoder.append(Data("\n".utf8))
        // 正常行が返ること
        let lines = decoder.append(Data("ok\n".utf8))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(String(data: lines[0], encoding: .utf8), "ok")
    }

    func testDroppedLineCount() {
        let decoder = LineBufferedEventDecoder()
        let oversizeLine = String(repeating: "a", count: 8193) + "\n"
        _ = decoder.append(Data(oversizeLine.utf8))
        XCTAssertEqual(decoder.droppedLineCount, 1)
        // 後続の正常行は受信される
        let lines = decoder.append(Data("normal\n".utf8))
        XCTAssertEqual(lines.count, 1)
    }
}
