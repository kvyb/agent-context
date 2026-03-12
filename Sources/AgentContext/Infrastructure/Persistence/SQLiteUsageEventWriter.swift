import Foundation

final class SQLiteUsageEventWriter: UsageEventWriting, @unchecked Sendable {
    private let database: SQLiteStore

    init(database: SQLiteStore) {
        self.database = database
    }

    func appendUsageEvent(_ event: LLMUsageEvent) async {
        try? await database.appendUsageEvent(event)
    }
}
