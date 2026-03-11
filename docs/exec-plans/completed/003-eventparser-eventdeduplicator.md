# 実装計画 003: EventParser + EventDeduplicator + HookServer 結線

## 概要

設計書 v11 §10.3（受信パイプライン）と §14.2（EventParser / EventDeduplicator）に基づき、NDJSON 行を型付きイベントに変換するパーサーと、重複イベントを排除するデデュプリケータを実装する。HookServer の onLines コールバックを parse + main thread handoff に置き換え、受信パイプラインの [1]→[2]→[3] を完成させる。

StateMachine との結合は本計画のスコープ外とし、[3] の出力は main thread 上の `onEvent` コールバックとして外部に提供する。

## 正典参照

- 設計書: `docs/design/current/clabotch_design_doc_v11.md`
- §10.3: 受信パイプライン（v8最終版）
- §14.1: NDJSON framing 仕様
- §14.2: EventParser / EventDeduplicator
- patch: `docs/design/patches/patch_002_socket_path.md`

## 正典からの逸脱（実装完了時に patch 文書に記録）

| # | 内容 | v11 正典 | 本計画 | 理由 |
|---|------|---------|--------|------|
| 1 | EventDeduplicator init | `private let ttl = 30` / `private let maxEntries = 512`（固定値） | `init(ttl:maxEntries:)` でデフォルト付き外部注入 | テスタビリティ（TTL/maxEntries のカスタム値でテスト可能にする） |
| 2 | EventDeduplicator 所有者 | グローバル1個（関数外スコープ） | AppDelegate が所有し HookServer に注入 | HookServer のライフサイクルと分離し、stop/start サイクルで deduplicator がリセットされないことを保証 |
| 3 | parse → main handoff のループ構造 | `compactMap(EventParser.parse)` | 明示的 `for` ループ + `os_log(.debug)` | parse nil 時のログ出力（pure function 側で副作用を持たないため呼び出し側で記録） |
| 4 | ClabotchEvent.unknown の型 | `unknown(raw: [String: Any])` | `unknown(rawJSON: String)` | `[String: Any]` は Equatable 非適合で手動 == が必要。JSON キー順序が非決定的でテスト脆弱。patch 文書: `docs/design/patches/patch_003_unknown_rawjson.md` |

## 前提条件

- [x] 計画 002 完了（HookServer + LineBufferedEventDecoder、Codex A）
- [x] 全53テスト合格（52 passed, 1 skipped）

## スコープ

**含む:**
- `ClabotchEvent` enum（イベント型定義）
- `ClabotchEnvelope` struct（event_id + event のペア）
- `EventParser`（pure function、Data → ClabotchEnvelope?）
- `EventDeduplicator`（main thread only、TTL + maxEntries ベースの重複排除）
- HookServer の onLines → parse + dedup + main thread handoff 結線
- 全テスト

**含まない:**
- StateMachine / GazeController との結合
- Stop hook error 対応

---

## Step 1: ClabotchEvent + ClabotchEnvelope 型定義

### 成果物

`src/Clabotch/ClabotchEvent.swift`

### 仕様（§14.2 準拠）

```swift
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
```

### unknown の Equatable 対応

`unknown(rawJSON:)` は元の JSON 行データを `String` として保持する。`[String: Any]` ではなく `String` を使うことで:
- `Equatable` が自動合成される（手動 `==` 実装不要）
- JSON キー順序の非決定性による等値比較の不安定さを排除
- EventParser.parse で元の行データ（Data → String 変換）を保持する

---

## Step 2: EventParser 実装

### 成果物

`src/Clabotch/EventParser.swift`

### 仕様（§14.2 準拠）

```swift
struct EventParser {
    /// pure function。任意スレッドで呼び出し可能。
    /// 不正な入力に対しては nil を返す（例外を投げない）。
    static func parse(_ data: Data) -> ClabotchEnvelope?
}
```

### パース手順

1. `JSONSerialization.jsonObject(with: data)` で `[String: Any]` に変換
2. 必須フィールドの検証:
   - `schema_version` (String): `"1"` のみ受理。不一致 → `nil`
   - `event_id` (String): `UUID(uuidString:)` で変換。不正 → `nil`
   - `event` (String): イベント種別文字列。欠損 → `nil`
   - `session_id` (String): 全イベントで必須。欠損 → `nil`
3. イベント種別ごとの追加フィールド検証:
   - `session_start`: 追加フィールドなし
   - `tool_start`: `tool_name` (String) 必須
   - `tool_end`: `tool_name` (String), `duration_ms` (Int), `is_error` (Bool) 必須。`error_message` (String?) 任意
   - `session_done`: `elapsed_ms` (Int) 任意（デフォルト 0）
   - その他: `.unknown(rawJSON: String(data: data, encoding: .utf8))` として受理（forward-compatible、元の行データを保持）

### エラー扱い方針（明文化）

| 入力 | 結果 | 理由 |
|------|------|------|
| 不正 JSON（パース不可） | `nil` | §14.1「不正 JSON 行はその行だけ破棄して継続」 |
| JSON だが Array や String | `nil` | トップレベルが Object でない |
| `schema_version` 欠損 or 不一致 | `nil` | 未知のスキーマは安全に無視 |
| `event_id` 欠損 or UUID 不正 | `nil` | デデュプリケーション不可のため破棄 |
| `event` 欠損 | `nil` | イベント種別不明は処理不可 |
| `session_id` 欠損 | `nil` | 全イベントで必須（設計書 v11） |
| 未知の `event` 文字列 | `.unknown(rawJSON:)` | forward-compatible（元の行データを String で保持） |
| `tool_start` で `tool_name` 欠損 | `nil` | 必須フィールド欠損 |
| `tool_end` で必須フィールド欠損 | `nil` | 必須フィールド欠損 |
| 余分なフィールド | 無視 | forward-compatible |

---

## Step 3: EventDeduplicator 実装

### 成果物

`src/Clabotch/EventDeduplicator.swift`

### 仕様（§14.2 準拠）

```swift
/// メインスレッド専用。グローバルに1インスタンス。
/// TTL + maxEntries ベースの重複排除。
final class EventDeduplicator {
    private let ttl: TimeInterval    // デフォルト 30秒
    private let maxEntries: Int      // デフォルト 512

    init(ttl: TimeInterval = 30, maxEntries: Int = 512)

    /// id が初出なら true、重複なら false。
    /// 呼び出しのたびに期限切れエントリを prune する。
    func shouldAccept(_ id: UUID, now: Date = Date()) -> Bool
}
```

### 内部構造

```swift
private struct Entry {
    let id: UUID
    let seenAt: Date
}
private var entries: [Entry] = []
```

### 動作仕様

1. `shouldAccept` 呼び出し時に `prune(now:)` で TTL 超過エントリを削除
2. `entries` に同一 `id` が存在すれば `false`（重複）
3. 新規 `id` を `entries` に追加
4. `entries.count > maxEntries` なら先頭（最古）から超過分を削除
5. `true` を返す

### スレッドセーフティ

- `dispatchPrecondition(condition: .onQueue(.main))` を `shouldAccept` 冒頭に配置
- テストでは `@MainActor` で実行

---

## Step 4: HookServer 結線変更

### 変更対象

`src/Clabotch/HookServer.swift`

### 変更内容

HookServer の init パラメータを `onLines: ([Data]) -> Void` から `onEvent: (ClabotchEnvelope) -> Void` に変更する。

**接続ごとの read ループ（connectionQueue 上）:**

```
[1] LineBufferedEventDecoder.append(chunk) → [Data]
[2] EventParser.parse(line) × N            → [ClabotchEnvelope]    ← 追加
[3] DispatchQueue.main.async {
      EventDeduplicator.shouldAccept(id)                           ← 追加
      onEvent(envelope)                                            ← 追加
    }
```

### 具体的な変更

1. `onLines: ([Data]) -> Void` → `onEvent: @escaping (ClabotchEnvelope) -> Void`
2. `EventDeduplicator` は HookServer の外部（AppDelegate）が所有し、init で注入する:
   ```swift
   init(socketDir: String,
        deduplicator: EventDeduplicator,
        onEvent: @escaping (ClabotchEnvelope) -> Void,
        ...)
   ```
   理由: 設計書 v11 §10.3 で deduplicator は「グローバル1個」と規定されている。HookServer 内部に保持すると、stop/start サイクルでリセットされ、重複イベントが通過するリスクがある。AppDelegate が所有することで HookServer のライフサイクルと分離する。

3. read ループ内の `self.onLines(lines)` を以下に置換:

```swift
// [2] parse（connectionQueue 上、pure function）
var envelopes: [ClabotchEnvelope] = []
for line in lines {
    if let envelope = EventParser.parse(line) {
        envelopes.append(envelope)
    } else {
        os_log(.debug, "EventParser: 行を破棄（不正 JSON または必須フィールド欠損）")
    }
}
```

4. generation チェックは parse 前（既存）に加え、main thread dispatch 時にも行う:

```swift
// [3] dedup + callback（main thread）
if !envelopes.isEmpty {
    DispatchQueue.main.async { [capturedGeneration] in
        let generationOk = self.stateQueue.sync { self.generation == capturedGeneration }
        guard generationOk else { return }
        for envelope in envelopes {
            guard self.deduplicator.shouldAccept(envelope.eventID) else { continue }
            self.onEvent(envelope)
        }
    }
}
```

**parse nil 時のログ出力方針:** EventParser は pure function であるため内部で副作用（ログ）を持たない。ログ出力は呼び出し側（HookServer の connectionQueue 上）で `for line in lines` ループを使い、`parse` が nil を返した場合に `os_log(.debug)` で記録する。`compactMap` ではなく明示的ループを使用する。

### AppDelegate 更新

`AppDelegate.swift` で EventDeduplicator を所有し、HookServer に注入:

```swift
private let deduplicator = EventDeduplicator()

// applicationDidFinishLaunching 内:
hookServer = HookServer(
    socketDir: socketDir,
    deduplicator: deduplicator,
    onEvent: { envelope in
        os_log(.info, "イベント受信: %{public}@", String(describing: envelope.event))
    },
    onListenerFailure: { error in
        os_log(.fault, "HookServer listener が停止: %{public}@", String(describing: error))
    }
)
```

---

## Step 5: テスト

### 5a: EventParserTests（15テスト）

`src/ClabotchTests/EventParserTests.swift`

**正常系 (5):**

| # | テスト名 | 内容 |
|---|----------|------|
| 1 | `testParseSessionStart` | 有効な session_start JSON → `.sessionStart` |
| 2 | `testParseToolStart` | 有効な tool_start JSON → `.toolStart` |
| 3 | `testParseToolEnd` | 有効な tool_end JSON → `.toolEnd`（errorMessage 含む） |
| 4 | `testParseToolEndWithoutErrorMessage` | error_message 省略 → `.toolEnd(errorMessage: nil)` |
| 5 | `testParseSessionDone` | 有効な session_done JSON → `.sessionDone` |

**異常系 (8):**

| # | テスト名 | 内容 |
|---|----------|------|
| 6 | `testInvalidJSON` | 不正 JSON バイト列 → `nil` |
| 7 | `testJSONArray` | `[1,2,3]` → `nil`（トップレベルが Object でない） |
| 8 | `testWrongSchemaVersion` | `schema_version: "2"` → `nil` |
| 9 | `testMissingSchemaVersion` | schema_version 欠損 → `nil` |
| 10 | `testInvalidEventID` | `event_id: "not-a-uuid"` → `nil` |
| 11 | `testMissingSessionID` | session_id 欠損 → `nil` |
| 12 | `testToolStartMissingToolName` | tool_start で tool_name 欠損 → `nil` |
| 13 | `testToolEndMissingRequiredFields` | tool_end で is_error 欠損 → `nil` |

**forward-compatible (2):**

| # | テスト名 | 内容 |
|---|----------|------|
| 14 | `testUnknownEventType` | `event: "future_event"` → `.unknown(rawJSON:)` |
| 15 | `testExtraFieldsIgnored` | 余分なフィールド付き session_start → 正常パース |

### 5b: EventDeduplicatorTests（7テスト）

`src/ClabotchTests/EventDeduplicatorTests.swift`

| # | テスト名 | 内容 |
|---|----------|------|
| 1 | `testFirstOccurrenceAccepted` | 初出 UUID → `true` |
| 2 | `testDuplicateRejected` | 同一 UUID 2回目 → `false` |
| 3 | `testTTLExpiry` | TTL 超過後の同一 UUID → `true`（再受理） |
| 4 | `testMaxEntriesEviction` | maxEntries 超過 → 最古エントリが追い出されて再受理可能 |
| 5 | `testDifferentIDsAccepted` | 異なる UUID → すべて `true` |
| 6 | `testPruneRemovesExpiredOnly` | 期限内・期限切れ混在 → 期限切れだけ削除 |
| 7 | `testCustomTTLAndMaxEntries` | init パラメータのカスタム値が反映される |

### 5c: HookServer 結線テスト（3テスト）

`src/ClabotchTests/HookServerTests.swift` の `HookServerIntegrationTests` に追加

| # | テスト名 | 内容 |
|---|----------|------|
| 1 | `testValidNDJSONProducesEvent` | 有効な NDJSON → `onEvent` で `ClabotchEnvelope` 受信 |
| 2 | `testInvalidJSONLineSkipped` | 不正 JSON 行 → `onEvent` 呼ばれず、後続の有効行は受信 |
| 3 | `testDuplicateEventIDFiltered` | 同一 event_id を2回送信 → `onEvent` は1回だけ |

---

## テスト合計

| スイート | 新規 | 既存 | 計 |
|----------|------|------|-----|
| EventParserTests | 15 | - | 15 |
| EventDeduplicatorTests | 7 | - | 7 |
| HookServerIntegrationTests | 3 | 18 | 21 |
| HookServerUnitTests | - | 21 | 21 |
| HookServerAppDelegateTests | - | 3 | 3 |
| LineBufferedEventDecoderTests | - | 11 | 11 |
| **合計** | **25** | **53** | **78** |

**注意:** 既存の HookServerTests は `onLines` → `onEvent` 変更に伴いシグネチャを更新する必要がある。既存テストの内部ロジック（mock の動作検証）は変わらないため、コールバックの型変更のみ。

### 既存テスト更新方針

HookServer の `onLines` → `onEvent` 変更に伴い、既存テストの更新が必要。

**重要:** 既存テストの送信データ（`"line1\n"` 等）は EventParser を通らないため、以下のいずれかで対応:
- 送信データを有効な NDJSON（schema_version + event_id + event + session_id）に変更
- または HookServer に `onRawLines` を残して段階的移行する

本計画では**送信データを有効な NDJSON に変更する**方針を採る。理由:
- `onRawLines` を残すと二重コールバック API になり、保守性が低下する
- 有効な NDJSON テストデータを使うことで、E2E パス全体の検証が強化される

### 既存テスト分類（onEvent 呼び出しの検証要否）

#### HookServerUnitTests（21件）— socket 層テスト

これらは MockSocketOps で accept/read/close の振る舞いを検証するテスト。`onEvent` の呼び出し自体は検証対象ではない。

| 変更内容 | 対象テスト |
|----------|-----------|
| `onLines: { _ in }` → `onEvent: { _ in }` のみ | testPathTooLong, testStartTwiceIsNoOp, testStartDuringStoppingThrows, testFaultedStartThrows, testStartRollbackOnListenFailure, testStopDoesNotTriggerListenerFailure, testStopCompletionIsAsync, testStopOutcomeStopped, testStopTimeoutDetection, testEMFILEBackoffDeterministic, testAccept5ConsecutiveFailuresTriggersListenerFailure, testTeardownUnification, testTerminateSyncDeletesSocket, testBindEADDRINUSEAlreadyRunning, testBindEADDRINUSEBindFailed, testAcceptEMFILEBackoffAndRecover, testMkdirEEXISTRace, testMkdirEEXISTRetryLimit, testListenerFailureAndStopOwnershipExclusion, testAcceptThenStopRaceWithTestHook |

これらのテストは read データがスタブであり EventParser.parse が nil を返すが、それは意図通り。テストの目的は socket ライフサイクル（accept/close/stop/teardown）の検証であり、onEvent が呼ばれないことは問題ない。

#### HookServerIntegrationTests（18件）— 実 socket テスト

| 分類 | 変更内容 | 対象テスト |
|------|----------|-----------|
| **onEvent 検証あり** | 送信データを `makeTestNDJSON` で有効な NDJSON に変更 + onEvent で ClabotchEnvelope を検証 | testSingleClientConnection, testMultipleClientsParallel, testSplitWrite, testNDJSONBatchOrder, testNoStaleEmitAfterStop |
| **onEvent 検証なし** | `onEvent: { _ in }` のみ | testEOFCleanup, testStopStopsAccepting, testStopThenRestart, testStopWithActiveConnection, testStopIdempotent, testRegularFileProtection, testSocketPermissions, testLiveSocketDetection, testSocketDirIsFile, testStaleSocketUnlink, testSocketDir0755Rejected, testConnectENOENTProbe, testSocketDirOwnerMismatch |

「onEvent 検証あり」の5件は、現在 `onLines` で raw Data の受信を検証しているテスト。これらを有効な NDJSON データ + `onEvent` での `ClabotchEnvelope` 検証に変更する。

「onEvent 検証なし」の13件は、socket 層の振る舞い（パーミッション、stale socket、stop 動作等）のみを検証するテスト。

#### HookServerAppDelegateTests（3件）

| 変更内容 | 対象テスト |
|----------|-----------|
| `onLines: { _ in }` → `onEvent: { _ in }` + deduplicator 注入 | testAlreadyRunningThrows, testTerminateSyncDuringStoppingIsNoOp, testTerminateSyncUnlinksSocket |

### テストデータヘルパー

`TestHelpers.swift` に追加:

```swift
/// テスト用の有効な NDJSON 行を生成
func makeTestNDJSON(
    event: String = "session_start",
    sessionID: String = "test-session",
    toolName: String? = nil,
    eventID: UUID = UUID()
) -> String {
    var json: [String: Any] = [
        "schema_version": "1",
        "event_id": eventID.uuidString,
        "event": event,
        "session_id": sessionID
    ]
    if let toolName = toolName {
        json["tool_name"] = toolName
    }
    if event == "tool_end" {
        json["duration_ms"] = 100
        json["is_error"] = false
    }
    if event == "session_done" {
        json["elapsed_ms"] = 1000
    }
    let data = try! JSONSerialization.data(withJSONObject: json)
    return String(data: data, encoding: .utf8)!
}
```

---

## 実装順序

1. **Step 1**: `ClabotchEvent.swift` + `ClabotchEnvelope` 型定義
2. **Step 2**: `EventParser.swift` 実装 + `EventParserTests.swift`（テスト先行）
3. **Step 3**: `EventDeduplicator.swift` 実装 + `EventDeduplicatorTests.swift`（テスト先行）
4. **Step 4**: HookServer 結線変更 + 既存テスト更新
5. **Step 5**: 結線テスト3件追加
6. **検証**: `xcodebuild test` で全78テスト合格

---

## リスクと対策

| リスク | 対策 |
|--------|------|
| 既存テストの NDJSON 変換漏れ | Step 4 で全既存テストの送信データを一括更新。「既存テスト分類」表に基づき onEvent 検証あり/なしを分類済み |
| unknown の Equatable 不安定 | `rawJSON: String` に変更し、Equatable を自動合成（JSON キー順序の非決定性を排除） |
| EventDeduplicator の main thread 制約がテストで検出困難 | `dispatchPrecondition` + `@MainActor` テストで保証 |
| parse nil 時の状況把握困難 | HookServer 側で明示的 for ループ + `os_log(.debug)` で記録。EventParser は pure function を維持 |
| deduplicator が HookServer 再起動でリセットされる | AppDelegate が所有し HookServer に注入。ライフサイクル分離を保証 |
