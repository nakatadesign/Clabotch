import Foundation

/// メインスレッド専用。AppDelegate が所有するグローバル1インスタンス。
/// TTL + maxEntries ベースの重複排除。
final class EventDeduplicator {

    private struct Entry {
        let id: UUID
        let seenAt: Date
    }

    private var entries: [Entry] = []
    private let ttl: TimeInterval
    private let maxEntries: Int

    init(ttl: TimeInterval = 30, maxEntries: Int = 512) {
        self.ttl = ttl
        self.maxEntries = maxEntries
    }

    /// id が初出なら true、重複なら false。
    /// 呼び出しのたびに期限切れエントリを prune する。
    func shouldAccept(_ id: UUID, now: Date = Date()) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))

        prune(now: now)
        if entries.contains(where: { $0.id == id }) { return false }
        entries.append(Entry(id: id, seenAt: now))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        return true
    }

    private func prune(now: Date) {
        entries.removeAll { now.timeIntervalSince($0.seenAt) > ttl }
    }
}
