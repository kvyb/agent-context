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
            return await taskSegmentHits(
                queries: queries,
                queryTerms: queryTerms,
                scope: scope,
                limit: limit
            )
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

        let taskSegmentOutput = await taskSegmentHits(
            queries: queries,
            queryTerms: queryTerms,
            scope: scope,
            limit: limit
        )

        return (output + taskSegmentOutput)
            .sorted {
                if abs($0.hybridScore - $1.hybridScore) > 0.0001 {
                    return $0.hybridScore > $1.hybridScore
                }
                return ($0.occurredAt ?? .distantPast) > ($1.occurredAt ?? .distantPast)
            }
            .reduce(into: [MemoryEvidenceHit]()) { acc, hit in
                if acc.contains(where: { $0.id == hit.id }) {
                    return
                }
                acc.append(hit)
            }
            .prefix(limit)
            .map { $0 }
    }

    private func taskSegmentHits(
        queries: [String],
        queryTerms: [String],
        scope: MemoryQueryScope,
        limit: Int
    ) async -> [MemoryEvidenceHit] {
        let lookupText = bestTaskSegmentLookupText(queries: queries, queryTerms: queryTerms)
        let segments: [TaskSegmentRecord]
        do {
            segments = try await database.queryTaskSegments(
                text: lookupText,
                start: scope.start,
                end: scope.end,
                limit: max(limit * 3, 24)
            )
        } catch {
            return []
        }

        guard !segments.isEmpty else {
            return []
        }

        let docs = segments.map { segment in
            taskSegmentDocument(segment)
        }.map(scopeParser.tokenize)
        let scores = ranker.score(documents: docs, queryTerms: queryTerms)
        let maxScore = max(scores.max() ?? 0, 0.000_1)

        var output: [MemoryEvidenceHit] = []
        var seen = Set<String>()

        for (index, segment) in segments.enumerated() {
            let rawScore = scores[index]
            guard rawScore > 0 else { continue }

            let lexicalScore = min(1, rawScore / maxScore)
            let ageHours = Date().timeIntervalSince(segment.occurredAt) / 3600
            let recencyBoost = ageHours < 24 ? 0.05 : (ageHours < 24 * 7 ? 0.03 : 0)
            let confidenceBoost = min(0.08, max(0, segment.confidence * 0.08))
            let key = "task-segment|\(segment.id)"
            guard seen.insert(key).inserted else { continue }

            output.append(
                MemoryEvidenceHit(
                    id: key,
                    source: .bm25Store,
                    text: taskSegmentSummary(segment),
                    appName: segment.appName?.nilIfEmpty,
                    project: segment.project?.nilIfEmpty,
                    occurredAt: segment.occurredAt,
                    metadata: [
                        "scope": segment.scope,
                        "workspace": segment.workspace ?? "",
                        "repo": segment.repo ?? "",
                        "document": segment.document ?? "",
                        "url": segment.url ?? "",
                        "entities": segment.entities.joined(separator: "|"),
                        "task_segment_status": segment.status.rawValue
                    ],
                    semanticScore: 0,
                    lexicalScore: lexicalScore,
                    hybridScore: lexicalScore + recencyBoost + confidenceBoost
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

    private func bestTaskSegmentLookupText(queries: [String], queryTerms: [String]) -> String {
        let exactQuery = queries.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !exactQuery.isEmpty {
            return exactQuery
        }
        return queryTerms.joined(separator: " ")
    }

    private func taskSegmentDocument(_ segment: TaskSegmentRecord) -> String {
        let actions = segment.actions.joined(separator: " ")
        let entities = segment.entities.joined(separator: " ")
        let fields = [
            segment.task,
            segment.issueOrGoal ?? "",
            actions,
            segment.outcome ?? "",
            segment.nextStep ?? "",
            segment.summary,
            segment.project ?? "",
            segment.appName ?? "",
            segment.workspace ?? "",
            segment.repo ?? "",
            segment.document ?? "",
            segment.url ?? "",
            entities,
            segment.status.rawValue,
            segment.scope
        ]
        return fields.joined(separator: " ")
    }

    private func taskSegmentSummary(_ segment: TaskSegmentRecord) -> String {
        let actions = segment.actions.prefix(3).joined(separator: "; ")
        let actionsPart = actions.isEmpty ? "" : " | Actions: \(actions)"
        let outcomePart = segment.outcome?.nilIfEmpty.map { " | Outcome: \($0)" } ?? ""
        let nextStepPart = segment.nextStep?.nilIfEmpty.map { " | Next step: \($0)" } ?? ""
        let issuePart = segment.issueOrGoal?.nilIfEmpty.map { " | Issue/Goal: \($0)" } ?? ""
        let projectPart = segment.project?.nilIfEmpty.map { " | Project: \($0)" } ?? ""
        return "Task: \(segment.task) | Status: \(segment.status.rawValue)\(issuePart)\(actionsPart)\(outcomePart)\(nextStepPart)\(projectPart)"
    }
}
