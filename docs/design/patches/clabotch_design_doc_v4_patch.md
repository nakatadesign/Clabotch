# Clabotch 設計仕様書 — v4追補（IPC / 単一セッション境界 / event_id整合）

> `clabotch_design_doc_v3.md` にそのまま追記できる補足章。  
> 本章は **§10.2 / §10.3 / §10.4 / §12.2 / §12.4** の補強を目的とする。  
> v3 と矛盾する場合は本章を優先する。

---

## 14. IPC と単一セッション境界の最終補強

### 14.1 Unix Socket の framing 仕様を確定する

v3 では hook 側が `printf(...)\n` で JSON を送っているが、  
Unix stream socket では **1回の read が 1イベントになる保証はない**。  
そのため、Clabotch の IPC は **NDJSON（1行 = 1 JSONイベント）** を正式仕様とする。

#### IPC 仕様

| 項目 | 仕様 |
|------|------|
| transport | Unix domain socket |
| payload format | UTF-8 NDJSON |
| framing | `\n` 区切り |
| 1イベント | 1行に 1つの JSON object |
| 空行 | 無視 |
| 途中までの行 | 次回 read まで内部バッファに保持 |
| 不正 JSON 行 | その行だけ破棄して継続 |
| 推奨最大行長 | 8 KB |

#### 明文化する運用ルール

- Hook script は必ず JSON の末尾に `\n` を付ける
- HookServer は `Data` をそのまま `JSONSerialization` に渡さない
- HookServer は **line buffer** を持ち、改行単位で `EventParser` に渡す
- 8 KB を超えた行は破棄してログだけ残す

#### HookServer 受信雛形

```swift
// MARK: - LineBufferedEventDecoder.swift

import Foundation

final class LineBufferedEventDecoder {

    private var buffer = Data()
    private let maxLineBytes = 8 * 1024

    func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []

        while let newlineRange = buffer.firstRange(of: Data([0x0A])) {
            let line = buffer.prefix(upTo: newlineRange.lowerBound)
            buffer.removeSubrange(..<newlineRange.upperBound)

            guard !line.isEmpty else { continue }
            guard line.count <= maxLineBytes else { continue }

            lines.append(Data(line))
        }

        if buffer.count > maxLineBytes {
            buffer.removeAll(keepingCapacity: true)
        }

        return lines
    }
}
```

#### HookServer 側の取り込みイメージ

```swift
let decoder = LineBufferedEventDecoder()

func handleIncomingData(_ chunk: Data) {
    for line in decoder.append(chunk) {
        guard let event = EventParser.parse(line) else { continue }
        stateMachine.handle(event: event)
    }
}
```

> これで「複数イベントが1 readにまとまる」「1イベントが複数 read に分割される」の両方に耐えられる。

---

### 14.2 `schema_version` と `event_id` の扱いを仕様と実装で一致させる

v3 では `schema_version` と `event_id` を必須としている一方、  
受信側の実装雛形では実際には検証していない。  
v4 では両者を **実際に使うフィールド** として確定する。

#### `schema_version`

- 現在サポートする値は `"1"` のみ
- 未知の version は `unknown` ではなく **破棄**
- 破棄理由を debug log に残す

#### `event_id`

- 目的は **短時間の重複除去**
- Hook 再送や socket 再接続時の二重表示を防ぐ
- 保持期間は `30秒` または `512件` のどちらか早い方まで

#### EventParser 修正版

```swift
// MARK: - ClabotchEnvelope.swift

import Foundation

struct ClabotchEnvelope {
    let eventID: UUID
    let event: ClabotchEvent
}

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
                sessionID: sessionID,
                toolName: toolName,
                durationMs: durationMs,
                isError: isError,
                errorMessage: json["error_message"] as? String
            )
        case "session_done":
            parsed = .sessionDone(sessionID: sessionID, elapsedMs: json["elapsed_ms"] as? Int ?? 0)
        default:
            parsed = .unknown(raw: json)
        }

        return ClabotchEnvelope(eventID: eventID, event: parsed)
    }
}
```

#### 重複除去キャッシュ雛形

```swift
// MARK: - EventDeduplicator.swift

import Foundation

final class EventDeduplicator {

    private struct Entry {
        let id: UUID
        let seenAt: Date
    }

    private var entries: [Entry] = []
    private let ttl: TimeInterval = 30
    private let maxEntries = 512

    func shouldAccept(_ id: UUID, now: Date = Date()) -> Bool {
        prune(now: now)

        if entries.contains(where: { $0.id == id }) {
            return false
        }

        entries.append(.init(id: id, seenAt: now))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        return true
    }

    private func prune(now: Date) {
        entries.removeAll { now.timeIntervalSince($0.seenAt) > ttl }
    }
}
```

#### 受信処理の最終形

```swift
let decoder = LineBufferedEventDecoder()
let deduplicator = EventDeduplicator()

func handleIncomingData(_ chunk: Data) {
    for line in decoder.append(chunk) {
        guard let envelope = EventParser.parse(line) else { continue }
        guard deduplicator.shouldAccept(envelope.eventID) else { continue }
        stateMachine.handle(event: envelope.event)
    }
}
```

---

### 14.3 single-session MVP の防御線を明文化する

v3 では複数セッションは MVP 対象外だが、  
実装雛形だけ見ると別セッションのイベントが来たときに表示が乗っ取られうる。  
そのため、MVP の StateMachine は **明示的 single-owner モード** とする。

#### single-owner ルール

| 状況 | 挙動 |
|------|------|
| `session == nil` で `session_start` | 受理して active session にする |
| active session と同じ `session_id` のイベント | 受理する |
| active session と異なる `tool_start` / `tool_end` | **無視して debug log のみ** |
| active session と異なる `session_start` | **無視して debug log のみ** |
| active session と異なる `session_done` | active session を壊さず、**軽量 done 通知のみ** を表示するか、MVP では無視する |

#### v4 の推奨方針

MVP は表示競合を避けることを優先し、以下で固定する。

- foreign `session_start` は無視
- foreign `tool_start` / `tool_end` は無視
- foreign `session_done` は **バブル通知のみ許可、フェーズ遷移はしない**

これにより、単一セッション前提の UI を壊さずに並行イベントをやり過ごせる。

#### StateMachine 修正版

```swift
final class StateMachine {

    private(set) var session: SessionState?
    private(set) var displayPhase: MascotPhase = .idle

    var onPhaseChanged: ((MascotPhase) -> Void)?
    var onEphemeralDone: ((Int) -> Void)?   // foreign session_done 用

    func handle(event: ClabotchEvent) {
        switch event {
        case .sessionStart(let sessionID):
            guard session == nil || session?.sessionID == sessionID else {
                debugLog("Ignoring foreign session_start: \(sessionID)")
                return
            }
            if session == nil {
                session = SessionState(
                    sessionID: sessionID,
                    phase: .thinking,
                    startedAt: Date(),
                    lastEventAt: Date()
                )
            }
            transition(to: .thinking)

        case .toolStart(let sessionID, let toolName):
            guard isActiveSession(sessionID) else {
                debugLog("Ignoring foreign tool_start: \(sessionID)")
                return
            }
            session?.phase = .working(toolName: toolName)
            transition(to: .working(toolName: toolName))

        case .toolEnd(let sessionID, let toolName, _, let isError, let errorMessage):
            guard isActiveSession(sessionID) else {
                debugLog("Ignoring foreign tool_end: \(sessionID)")
                return
            }
            if isError {
                transition(to: .error(toolName: toolName, message: errorMessage))
            } else {
                transition(to: .thinking)
            }

        case .sessionDone(let sessionID, let elapsedMs):
            guard isActiveSession(sessionID) else {
                debugLog("Foreign session_done -> ephemeral bubble only: \(sessionID)")
                onEphemeralDone?(elapsedMs)
                return
            }
            session = nil
            transition(to: .done(elapsedMs: elapsedMs))

        case .unknown:
            break
        }
    }
}
```

#### UI ルール

- `onEphemeralDone` はメニューバーの大きな完了アニメを起こさない
- 必要なら小さな吹き出しだけ出す
- foreign session は `displayPhase` を変更しない

> これで v0.3 未満でも「偶発的な並列セッション」に耐えられる。

---

### 14.4 MVP スコープの注記を追加する

`§12.4 MVP スコープ` に次の注記を追加する。

#### 含めるものに追加

- HookServer の NDJSON line buffer
- `schema_version == "1"` 検証
- `event_id` の短期重複除去
- single-session guard

#### 含めないものに追加

- 複数セッションのフェーズ統合表示
- foreign session の本格的な状態可視化
- event replay / persistence

---

### 14.5 実装順の補正

最終的な実装順は以下に更新する。

1. Hook 環境変数の実機確認
2. HookServer の NDJSON line buffer 実装
3. EventParser の `schema_version` / `event_id` 検証
4. EventDeduplicator 実装
5. Single-session StateMachine guard 実装
6. GazeController 実装
7. Warp AX 調査

> HookServer と parser の境界を先に固めると、後段の状態遷移デバッグが大幅に楽になる。

---

*追補案 — 2026-03-10*  
*Clabotch — v4 patch for IPC and session boundary*
