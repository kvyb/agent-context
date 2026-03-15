import Foundation

final class MemoryQueryUseCase: @unchecked Sendable {
    private let semanticRetriever: SemanticMemoryRetrieving
    private let lexicalRetriever: LexicalMemoryRetrieving
    private let planner: MemoryQueryPlanning
    private let answerer: MemoryQueryAnswering
    private let usageWriter: UsageEventWriting
    private let scopeParser: MemoryQueryScopeParser
    private let calendar: Calendar

    init(
        semanticRetriever: SemanticMemoryRetrieving,
        lexicalRetriever: LexicalMemoryRetrieving,
        planner: MemoryQueryPlanning,
        answerer: MemoryQueryAnswering,
        usageWriter: UsageEventWriting,
        scopeParser: MemoryQueryScopeParser,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.semanticRetriever = semanticRetriever
        self.lexicalRetriever = lexicalRetriever
        self.planner = planner
        self.answerer = answerer
        self.usageWriter = usageWriter
        self.scopeParser = scopeParser
        self.calendar = calendar
    }

    func execute(request: MemoryQueryRequest) async -> MemoryQueryResult {
        let trimmed = request.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return MemoryQueryResult(
                query: request.question,
                answer: "Enter a question to query memory.",
                keyPoints: [],
                supportingEvents: [],
                insufficientEvidence: true,
                mem0SemanticCount: 0,
                bm25StoreCount: 0,
                scope: MemoryQueryScope(start: nil, end: nil, label: nil),
                generatedAt: Date()
            )
        }

        let now = Date()
        let timeZone = calendar.timeZone
        let fallbackScope = scopeParser.inferScope(for: trimmed, referenceDate: now)

        var detailLevel: MemoryQueryDetailLevel = .concise
        var scope = fallbackScope
        var mem0Evidence: [MemoryEvidenceHit] = []
        var bm25Evidence: [MemoryEvidenceHit] = []
        var executedQueryKeys = Set<String>()
        var executedQueries: [String] = []
        var previousEvidenceCount = 0
        let absoluteMaxPasses = 6

        for pass in 1...absoluteMaxPasses {
            let planningQuestion = plannerQuestion(
                originalQuestion: trimmed,
                pass: pass,
                scope: scope,
                executedQueries: executedQueries,
                mem0Evidence: mem0Evidence,
                bm25Evidence: bm25Evidence
            )

            let plannerResult = await planner.plan(
                question: planningQuestion,
                now: now,
                detailLevel: detailLevel,
                timeZone: timeZone
            )
            if let usage = plannerResult?.usage {
                await usageWriter.appendUsageEvent(usage)
            }

            if let plannedLevel = plannerResult?.plan.detailLevel {
                detailLevel = plannedLevel
            }

            scope = resolvedScope(
                question: trimmed,
                plannerScope: plannerResult?.plan.scope,
                fallbackScope: fallbackScope
            )

            let plannerQueries = plannerResult?.plan.queries ?? []
            let normalized = scopeParser.normalizedQueries(for: trimmed, plannerQueries: plannerQueries)

            var newQueries: [String] = []
            for query in normalized {
                let key = query.lowercased()
                if executedQueryKeys.insert(key).inserted {
                    newQueries.append(query)
                    executedQueries.append(query)
                }
            }
            if pass == 1 && newQueries.isEmpty {
                let fallbackKey = trimmed.lowercased()
                if executedQueryKeys.insert(fallbackKey).inserted {
                    newQueries = [trimmed]
                    executedQueries.append(trimmed)
                }
            }
            guard !newQueries.isEmpty else { break }

            let retrievalPlan = retrievalPlan(for: detailLevel)
            let semanticHits = await semanticRetriever.retrieve(
                queries: newQueries,
                scope: scope,
                limit: retrievalPlan.perPassSemanticLimit
            )
            let lexicalHits = await lexicalRetriever.retrieve(
                queries: newQueries,
                scope: scope,
                limit: retrievalPlan.perPassLexicalLimit
            )
            mem0Evidence = mergeMem0(mem0Evidence, semanticHits, limit: retrievalPlan.semanticLimit)
            bm25Evidence = mergeBM25(bm25Evidence, lexicalHits, limit: retrievalPlan.lexicalLimit)

            if detailLevel == .detailed {
                let dayScopes = dailyScopes(from: scope, maxDays: retrievalPlan.maxDailySlices)
                for dayScope in dayScopes {
                    let dailySemanticHits = await semanticRetriever.retrieve(
                        queries: newQueries,
                        scope: dayScope,
                        limit: retrievalPlan.dailySemanticLimit
                    )
                    let dailyLexicalHits = await lexicalRetriever.retrieve(
                        queries: newQueries,
                        scope: dayScope,
                        limit: retrievalPlan.dailyLexicalLimit
                    )
                    mem0Evidence = mergeMem0(mem0Evidence, dailySemanticHits, limit: retrievalPlan.semanticLimit)
                    bm25Evidence = mergeBM25(bm25Evidence, dailyLexicalHits, limit: retrievalPlan.lexicalLimit)
                }
            }

            let totalEvidenceCount = mem0Evidence.count + bm25Evidence.count
            let gained = totalEvidenceCount - previousEvidenceCount
            previousEvidenceCount = totalEvidenceCount

            if pass >= retrievalPlan.maxPlannerPasses { break }
            if totalEvidenceCount >= retrievalPlan.targetEvidenceCount { break }
            if pass >= retrievalPlan.minPassesBeforeStop && gained <= retrievalPlan.minEvidenceGainPerPass {
                break
            }
        }

        guard !mem0Evidence.isEmpty || !bm25Evidence.isEmpty else {
            return MemoryQueryResult(
                query: trimmed,
                answer: "No matching memories found in Mem0/BM25 memory stores.",
                keyPoints: [],
                supportingEvents: [],
                insufficientEvidence: true,
                mem0SemanticCount: 0,
                bm25StoreCount: 0,
                scope: scope,
                generatedAt: Date()
            )
        }

        let payload: MemoryQueryAnswerPayload
        if let answerResult = await answerer.answer(
            question: trimmed,
            scope: scope,
            detailLevel: detailLevel,
            now: now,
            timeZone: timeZone,
            mem0Evidence: mem0Evidence,
            bm25Evidence: bm25Evidence
        ) {
            if let usage = answerResult.usage {
                await usageWriter.appendUsageEvent(usage)
            }
            payload = answerResult.payload
        } else {
            payload = fallbackPayload(
                question: trimmed,
                scopeLabel: scope.label,
                detailLevel: detailLevel,
                mem0Evidence: mem0Evidence,
                bm25Evidence: bm25Evidence
            )
        }

        return MemoryQueryResult(
            query: trimmed,
            answer: payload.answer,
            keyPoints: payload.keyPoints,
            supportingEvents: payload.supportingEvents,
            insufficientEvidence: payload.insufficientEvidence,
            mem0SemanticCount: mem0Evidence.count,
            bm25StoreCount: bm25Evidence.count,
            scope: scope,
            generatedAt: Date()
        )
    }

    private func fallbackPayload(
        question: String,
        scopeLabel: String?,
        detailLevel: MemoryQueryDetailLevel,
        mem0Evidence: [MemoryEvidenceHit],
        bm25Evidence: [MemoryEvidenceHit]
    ) -> MemoryQueryAnswerPayload {
        let scopedTitle: String
        if let scopeLabel = scopeLabel?.nilIfEmpty {
            scopedTitle = "Best matches (\(scopeLabel))"
        } else {
            scopedTitle = "Best matches"
        }

        let evidenceLimit = detailLevel == .detailed ? 32 : 8
        let mem0Lines = mem0Evidence.prefix(evidenceLimit).map(formatEvidenceLine)
        let bm25Lines = bm25Evidence.prefix(evidenceLimit).map(formatEvidenceLine)
        let answer = ([scopedTitle, "Question: \(question)", "Mem0 semantic matches:"]
            + (mem0Lines.isEmpty ? ["- none"] : mem0Lines)
            + ["BM25 storage matches:"]
            + (bm25Lines.isEmpty ? ["- none"] : bm25Lines))
            .joined(separator: "\n")

        return MemoryQueryAnswerPayload(
            answer: answer,
            keyPoints: [],
            supportingEvents: [],
            insufficientEvidence: true
        )
    }

    private func formatEvidenceLine(_ hit: MemoryEvidenceHit) -> String {
        let iso = ISO8601DateFormatter()
        let timestamp = hit.occurredAt.map { iso.string(from: $0) } ?? "unknown-time"
        let app = hit.appName?.nilIfEmpty ?? "unknown-app"
        let project = hit.project?.nilIfEmpty ?? hit.metadata["project"]?.nilIfEmpty ?? ""
        let projectSuffix = project.isEmpty ? "" : " | project=\(project)"
        let sourceScore: Double
        switch hit.source {
        case .mem0Semantic:
            sourceScore = hit.semanticScore
        case .bm25Store:
            sourceScore = hit.lexicalScore
        }

        return "- [\(timestamp)] source=\(hit.source.rawValue) score=\(String(format: "%.2f", sourceScore)) app=\(app)\(projectSuffix) | \(hit.text)"
    }

    private func resolvedScope(
        question: String,
        plannerScope: MemoryQueryScope?,
        fallbackScope: MemoryQueryScope
    ) -> MemoryQueryScope {
        if scopeParser.hasExplicitDate(in: question) {
            return fallbackScope
        }

        guard let plannerScope else {
            return fallbackScope
        }

        let start = plannerScope.start ?? fallbackScope.start
        let end = plannerScope.end ?? fallbackScope.end
        let label = plannerScope.label?.nilIfEmpty ?? fallbackScope.label
        return MemoryQueryScope(start: start, end: end, label: label)
    }

    private func dailyScopes(from scope: MemoryQueryScope, maxDays: Int) -> [MemoryQueryScope] {
        guard let start = scope.start, let end = scope.end, end > start else {
            return []
        }

        let dayStart = calendar.startOfDay(for: start)
        let lastStart = calendar.startOfDay(for: end.addingTimeInterval(-1))
        let dayCount = calendar.dateComponents([.day], from: dayStart, to: lastStart).day ?? 0
        guard dayCount >= 1 else {
            return []
        }

        var slices: [MemoryQueryScope] = []
        var cursor = dayStart

        while cursor <= lastStart && slices.count < maxDays {
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            let clampedEnd = min(next, end)
            let label = scope.label.map { "\($0) • \(isoDay(cursor))" } ?? isoDay(cursor)
            slices.append(
                MemoryQueryScope(start: cursor, end: clampedEnd, label: label)
            )
            cursor = next
        }

        return slices
    }

    private func mergeMem0(
        _ lhs: [MemoryEvidenceHit],
        _ rhs: [MemoryEvidenceHit],
        limit: Int
    ) -> [MemoryEvidenceHit] {
        var merged = Dictionary(uniqueKeysWithValues: lhs.map { ($0.id, $0) })
        for hit in rhs {
            if let existing = merged[hit.id], existing.semanticScore >= hit.semanticScore {
                continue
            }
            merged[hit.id] = hit
        }

        return merged.values
            .sorted {
                if abs($0.semanticScore - $1.semanticScore) > 0.0001 {
                    return $0.semanticScore > $1.semanticScore
                }
                return ($0.occurredAt ?? .distantPast) > ($1.occurredAt ?? .distantPast)
            }
            .prefix(limit)
            .map { $0 }
    }

    private func mergeBM25(
        _ lhs: [MemoryEvidenceHit],
        _ rhs: [MemoryEvidenceHit],
        limit: Int
    ) -> [MemoryEvidenceHit] {
        var merged = Dictionary(uniqueKeysWithValues: lhs.map { ($0.id, $0) })
        for hit in rhs {
            if let existing = merged[hit.id], existing.hybridScore >= hit.hybridScore {
                continue
            }
            merged[hit.id] = hit
        }

        return merged.values
            .sorted {
                if abs($0.hybridScore - $1.hybridScore) > 0.0001 {
                    return $0.hybridScore > $1.hybridScore
                }
                return ($0.occurredAt ?? .distantPast) > ($1.occurredAt ?? .distantPast)
            }
            .prefix(limit)
            .map { $0 }
    }

    private func retrievalPlan(for detailLevel: MemoryQueryDetailLevel) -> MemoryQueryRetrievalPlan {
        switch detailLevel {
        case .concise:
            return MemoryQueryRetrievalPlan(
                semanticLimit: 90,
                lexicalLimit: 70,
                perPassSemanticLimit: 36,
                perPassLexicalLimit: 28,
                dailySemanticLimit: 0,
                dailyLexicalLimit: 0,
                maxDailySlices: 0,
                maxPlannerPasses: 2,
                targetEvidenceCount: 70,
                minPassesBeforeStop: 1,
                minEvidenceGainPerPass: 0
            )
        case .detailed:
            return MemoryQueryRetrievalPlan(
                semanticLimit: 220,
                lexicalLimit: 180,
                perPassSemanticLimit: 64,
                perPassLexicalLimit: 52,
                dailySemanticLimit: 20,
                dailyLexicalLimit: 16,
                maxDailySlices: 14,
                maxPlannerPasses: 5,
                targetEvidenceCount: 180,
                minPassesBeforeStop: 2,
                minEvidenceGainPerPass: 3
            )
        }
    }

    private func isoDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func plannerQuestion(
        originalQuestion: String,
        pass: Int,
        scope: MemoryQueryScope,
        executedQueries: [String],
        mem0Evidence: [MemoryEvidenceHit],
        bm25Evidence: [MemoryEvidenceHit]
    ) -> String {
        guard pass > 1 else {
            return originalQuestion
        }

        let scopeLabel = scope.label?.nilIfEmpty ?? "unspecified"
        let scopeStart = scope.start.map(isoDay) ?? ""
        let scopeEnd = scope.end.map(isoDay) ?? ""
        let priorQueries = executedQueries.prefix(24).map { "- \($0)" }.joined(separator: "\n")

        let evidencePreview: [String] = (mem0Evidence + bm25Evidence)
            .sorted { ($0.occurredAt ?? .distantPast) > ($1.occurredAt ?? .distantPast) }
            .prefix(24)
            .map { hit in
                let timestamp = hit.occurredAt.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown-time"
                return "- [\(timestamp)] \((hit.appName ?? "unknown-app")) | \(hit.text)"
            }

        let previewText = evidencePreview.isEmpty ? "- none yet" : evidencePreview.joined(separator: "\n")

        return """
        Original question:
        \(originalQuestion)

        Planning pass: \(pass)
        Already executed queries (do not repeat):
        \(priorQueries.isEmpty ? "- none" : priorQueries)

        Current scope: \(scopeLabel)
        Scope start: \(scopeStart)
        Scope end: \(scopeEnd)
        Current evidence counts: mem0=\(mem0Evidence.count), bm25=\(bm25Evidence.count)
        Evidence preview:
        \(previewText)

        Return only new, non-duplicate retrieval queries that fill missing details and chronology gaps.
        """
    }
}

private struct MemoryQueryRetrievalPlan {
    let semanticLimit: Int
    let lexicalLimit: Int
    let perPassSemanticLimit: Int
    let perPassLexicalLimit: Int
    let dailySemanticLimit: Int
    let dailyLexicalLimit: Int
    let maxDailySlices: Int
    let maxPlannerPasses: Int
    let targetEvidenceCount: Int
    let minPassesBeforeStop: Int
    let minEvidenceGainPerPass: Int
}
