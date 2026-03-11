import XCTest
@testable import Clabotch

// MARK: - EventDeduplicatorTests（メインスレッド専用、required 7）

@MainActor
final class EventDeduplicatorTests: XCTestCase {

    // 1. 初回イベントは受理される
    func testFirstEventAccepted() {
        let dedup = EventDeduplicator()
        let id = UUID()
        XCTAssertTrue(dedup.shouldAccept(id))
    }

    // 2. 同一 event_id の重複は拒否
    func testDuplicateEventRejected() {
        let dedup = EventDeduplicator()
        let id = UUID()
        XCTAssertTrue(dedup.shouldAccept(id))
        XCTAssertFalse(dedup.shouldAccept(id))
    }

    // 3. TTL 超過後は同一 ID が再受理される
    func testExpiredEventAcceptedAgain() {
        let dedup = EventDeduplicator(ttl: 1.0)
        let id = UUID()
        let t0 = Date()

        XCTAssertTrue(dedup.shouldAccept(id, now: t0))
        XCTAssertFalse(dedup.shouldAccept(id, now: t0.addingTimeInterval(0.5)))
        // TTL 超過
        XCTAssertTrue(dedup.shouldAccept(id, now: t0.addingTimeInterval(1.1)))
    }

    // 4. maxEntries 超過で古いエントリが evict される
    func testMaxEntriesEviction() {
        let dedup = EventDeduplicator(ttl: 60, maxEntries: 3)
        let ids = (0..<4).map { _ in UUID() }

        for id in ids {
            XCTAssertTrue(dedup.shouldAccept(id))
        }

        // ids[0] は evict されているはず → 再受理
        XCTAssertTrue(dedup.shouldAccept(ids[0]))
        // ids[3] はまだ残っている → 拒否
        XCTAssertFalse(dedup.shouldAccept(ids[3]))
    }

    // 5. prune で期限切れエントリが除去される
    func testPruneRemovesExpired() {
        let dedup = EventDeduplicator(ttl: 1.0, maxEntries: 512)
        let t0 = Date()
        let oldID = UUID()
        let newID = UUID()

        XCTAssertTrue(dedup.shouldAccept(oldID, now: t0))
        XCTAssertTrue(dedup.shouldAccept(newID, now: t0.addingTimeInterval(0.5)))

        // t0+1.1 で prune → oldID は消える、newID は残る
        XCTAssertTrue(dedup.shouldAccept(oldID, now: t0.addingTimeInterval(1.1)))
        XCTAssertFalse(dedup.shouldAccept(newID, now: t0.addingTimeInterval(1.1)))
    }

    // 6. 異なる ID は全て受理される
    func testDifferentIDsAllAccepted() {
        let dedup = EventDeduplicator()
        for _ in 0..<10 {
            XCTAssertTrue(dedup.shouldAccept(UUID()))
        }
    }

    // 7. maxEntries ちょうどの境界値
    func testMaxEntriesBoundary() {
        let dedup = EventDeduplicator(ttl: 60, maxEntries: 2)
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()

        XCTAssertTrue(dedup.shouldAccept(id1))
        XCTAssertTrue(dedup.shouldAccept(id2))
        // maxEntries=2 なので、id1, id2 が保持されている
        XCTAssertFalse(dedup.shouldAccept(id1))
        XCTAssertFalse(dedup.shouldAccept(id2))

        // id3 追加で id1 が evict
        XCTAssertTrue(dedup.shouldAccept(id3))
        XCTAssertTrue(dedup.shouldAccept(id1)) // evict されたので再受理
        // id1 追加で id2 が evict
        XCTAssertTrue(dedup.shouldAccept(id2)) // evict されたので再受理
    }
}
