import Foundation

final class SQLiteBM25MemoryRetriever: LexicalMemoryRetrieving, @unchecked Sendable {
    private let database: SQLiteStore
    private let ranker: BM25Ranker
    private let scopeParser: MemoryQueryScopeParser

    init(
        database: SQLiteStore,
        ranker: BM25Ranker,
        scopeParser: MemoryQueryScopeParser
    ) {
        self.database = database
        self.ranker = ranker
        self.scopeParser = scopeParser
    }

    func retrieve(queries: [String], scope: MemoryQueryScope, limit: Int) async -> [MemoryEvidenceHit] {
        let queryTerms = scopeParser.queryTerms(for: queries.joined(separator: " "))
        guard !queryTerms.isEmpty else {
            return []
        }

        let scopedRows: [MemoryRecord]
        do {
            scopedRows = try await database.listMem0MemoryRecords(
                start: scope.start,
                end: scope.end,
                limit: 500
            )
        } catch {
            return []
        }

        let rows: [MemoryRecord]
        if scopedRows.isEmpty, (scope.start != nil || scope.end != nil) {
            rows = (try? await database.listMem0MemoryRecords(start: nil, end: nil, limit: 400)) ?? []
        } else {
            rows = scopedRows
        }
        guard !rows.isEmpty else {
            return []
        }

        let docs = rows.map { row in
            let entities = row.entities.joined(separator: " ")
            let project = row.project?.nilIfEmpty ?? ""
            let app = row.appName?.nilIfEmpty ?? ""
            return "\(row.summary) \(project) \(app) \(entities) \(row.scope)"
        }.map(scopeParser.tokenize)

        let scores = ranker.score(documents: docs, queryTerms: queryTerms)
        let maxScore = max(scores.max() ?? 0, 0.000_1)

        var output: [MemoryEvidenceHit] = []
        var seen = Set<String>()

        for (index, row) in rows.enumerated() {
            let rawScore = scores[index]
            guard rawScore > 0 else { continue }

            let lexicalScore = min(1, rawScore / maxScore)
            let ageHours = Date().timeIntervalSince(row.occurredAt) / 3600
            let recencyBoost = ageHours < 24 ? 0.04 : (ageHours < 24 * 7 ? 0.02 : 0)

            let key = "bm25|\(Int(row.occurredAt.timeIntervalSince1970 / 30))|\(row.summary.prefix(120).lowercased())"
            guard seen.insert(key).inserted else { continue }

            output.append(
                MemoryEvidenceHit(
                    id: key,
                    source: .bm25Store,
                    text: row.summary,
                    appName: row.appName?.nilIfEmpty,
                    project: row.project?.nilIfEmpty,
                    occurredAt: row.occurredAt,
                    metadata: [
                        "scope": row.scope,
                        "entities": row.entities.joined(separator: "|")
                    ],
                    semanticScore: 0,
                    lexicalScore: lexicalScore,
                    hybridScore: lexicalScore + recencyBoost
                )
            )
        }

        return output
            .sorted {
                if abs($0.hybridScore - $1.hybridScore) > 0.0001 {
                    return $0.hybridScore > $1.hybridScore
                }
                return ($0.occurredAt ?? .distantPast) > ($1.occurredAt ?? .distantPast)
            }
            .prefix(limit)
            .map { $0 }
    }
}
