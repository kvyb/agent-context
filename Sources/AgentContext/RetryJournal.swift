import Foundation

actor RetryJournal {
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var items: [String: RetryArtifactItem] = [:]

    init(url: URL) {
        self.url = url
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
    }

    func load() {
        guard
            let data = try? Data(contentsOf: url),
            let decoded = try? decoder.decode([RetryArtifactItem].self, from: data)
        else {
            return
        }

        items = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
    }

    func save() {
        let allItems = Array(items.values).sorted { $0.nextAttemptAt < $1.nextAttemptAt }
        guard let data = try? encoder.encode(allItems) else { return }

        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    func upsert(_ item: RetryArtifactItem) {
        items[item.id] = item
        save()
    }

    func remove(id: String) {
        items.removeValue(forKey: id)
        save()
    }

    func dueItems(now: Date) -> [RetryArtifactItem] {
        items.values
            .filter { !$0.failedPermanently && $0.nextAttemptAt <= now }
            .sorted { $0.nextAttemptAt < $1.nextAttemptAt }
    }

    func allItems() -> [RetryArtifactItem] {
        items.values.sorted { $0.nextAttemptAt < $1.nextAttemptAt }
    }

    func markAttempt(id: String, error: String?, nextAttemptAt: Date?, failedPermanently: Bool) {
        guard var item = items[id] else { return }
        item.attempts += 1
        item.lastError = error
        if let nextAttemptAt {
            item.nextAttemptAt = nextAttemptAt
        }
        item.failedPermanently = failedPermanently
        items[id] = item
        save()
    }
}
