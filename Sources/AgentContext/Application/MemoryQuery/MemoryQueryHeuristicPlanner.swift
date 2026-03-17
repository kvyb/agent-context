import Foundation

struct QueryIntentProfile: Sendable {
    let prefersLexicalFirst: Bool
}

struct MemoryQueryHeuristicPlanner: Sendable {
    private let scopeParser: MemoryQueryScopeParser

    init(scopeParser: MemoryQueryScopeParser) {
        self.scopeParser = scopeParser
    }

    func profile(for question: String) -> QueryIntentProfile {
        let lowered = question.lowercased()
        let transcriptLikeTerms = ["transcript", "interview", "meeting", "zoom", "call", "candidate", "notetaker"]
        let prefersLexicalFirst = transcriptLikeTerms.contains { lowered.contains($0) }
        return QueryIntentProfile(prefersLexicalFirst: prefersLexicalFirst)
    }

    func fallbackPlanResult(
        for question: String,
        fallbackScope: MemoryQueryScope,
        detailLevel: MemoryQueryDetailLevel,
        requestOptions: MemoryQueryOptions
    ) -> MemoryQueryPlanResult? {
        let queryProfile = profile(for: question)
        let steps = defaultPlanSteps(
            for: question,
            requestOptions: requestOptions,
            profile: queryProfile
        )
        guard !steps.isEmpty else {
            return nil
        }

        return MemoryQueryPlanResult(
            plan: MemoryQueryPlan(
                steps: steps,
                scope: fallbackScope,
                detailLevel: detailLevel
            ),
            usage: nil
        )
    }

    func defaultPlanSteps(
        for question: String,
        requestOptions: MemoryQueryOptions,
        profile: QueryIntentProfile
    ) -> [MemoryQueryPlanStep] {
        let plannedQueries = plannerQueries(for: question)
        let queries = plannedQueries.isEmpty ? [question] : plannedQueries

        var steps: [MemoryQueryPlanStep] = []

        if profile.prefersLexicalFirst && requestOptions.includesLexicalSearch {
            for query in queries.prefix(2) {
                steps.append(
                    MemoryQueryPlanStep(
                        query: query,
                        sources: [.bm25Store],
                        phase: .research,
                        maxResults: 6
                    )
                )
            }
        }

        for query in queries.prefix(4) {
            var sources = requestOptions.sources
            if profile.prefersLexicalFirst && requestOptions.includesLexicalSearch {
                sources.insert(.bm25Store)
            }

            steps.append(
                MemoryQueryPlanStep(
                    query: query,
                    sources: sources,
                    phase: .evidence,
                    maxResults: profile.prefersLexicalFirst ? 6 : 5
                )
            )
        }

        return steps
    }

    private func plannerQueries(for question: String) -> [String] {
        let normalizedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = scopeParser.queryTerms(for: normalizedQuestion)
        guard !tokens.isEmpty else {
            return []
        }

        var seen = Set<String>()
        var queries: [String] = []

        func add(_ value: String?) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { return }
            let key = value.lowercased()
            guard seen.insert(key).inserted else { return }
            queries.append(value)
        }

        let significantTokens = Array(tokens.prefix(6))
        add(significantTokens.joined(separator: " "))

        if significantTokens.count >= 2 {
            for index in 0..<(significantTokens.count - 1) {
                add("\(significantTokens[index]) \(significantTokens[index + 1])")
            }
        }

        let tokenSet = Set(significantTokens)
        if tokenSet.contains("transcript") {
            let withoutTranscript = significantTokens.filter { $0 != "transcript" }
            add(withoutTranscript.joined(separator: " "))
            add("meeting transcript")
        }
        if tokenSet.contains("interview") {
            add("technical interview")
            add("candidate interview")
        }
        if tokenSet.contains("zoom") {
            add("zoom meeting")
        }
        if tokenSet.contains("zoom") && tokenSet.contains("interview") {
            add("zoom interview")
        }

        return Array(queries.prefix(6))
    }
}
