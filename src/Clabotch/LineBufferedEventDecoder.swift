import Foundation
import os.log

/// NDJSON framing デコーダ。接続ごとに生成（共有禁止）。
/// `\n` で行分割し、空行は無視、8KB 超過行は完全破棄する。
final class LineBufferedEventDecoder {
    private var buffer = Data()
    private var droppingOversizeLine = false
    private let maxLineBytes = 8 * 1024
    private(set) var droppedLineCount: UInt64 = 0

    /// テスト用: 現在のバッファ要素数
    var currentBufferCount: Int { buffer.count }

    /// chunk を追加し、完成した行を返す。
    func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []

        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: nl)
            buffer.removeSubrange(...nl)

            if droppingOversizeLine {
                droppingOversizeLine = false
                droppedLineCount += 1
                os_log(.debug, "LineBufferedEventDecoder: oversize 行の後半を破棄")
                continue
            }
            guard !line.isEmpty else { continue }
            if line.count > maxLineBytes {
                droppedLineCount += 1
                os_log(.debug, "LineBufferedEventDecoder: %d バイトの oversize 行を破棄", line.count)
                continue
            }
            lines.append(Data(line))
        }

        // 改行なしで 8KB 超 → バッファ破棄 + 次の改行まで破棄フラグ ON
        if buffer.count > maxLineBytes {
            buffer = Data()
            droppingOversizeLine = true
        }

        return lines
    }
}
