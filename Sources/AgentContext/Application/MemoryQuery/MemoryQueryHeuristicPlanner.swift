import Foundation

struct QueryIntentProfile: Sendable {
    let prefersLexicalFirst: Bool
    let prefersDetailedAnswer: Bool
    let requestedFacets: [String]
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

        let detailedTerms = [
            "timeline",
            "projects",
            "tasks",
            "takeaways",
            "struggles",
            "blockers",
            "strengths",
            "weaknesses",
            "fit",
            "match",
            "level",
            "questions answered",
            "questions",
            "everything",
            "comprehensive",
            "summarize",
            "summary"
        ]
        let prefersDetailedAnswer = scopeParser.hasExplicitDate(in: question)
            || detailedTerms.contains { lowered.contains($0) }

        return QueryIntentProfile(
            prefersLexicalFirst: prefersLexicalFirst,
            prefersDetailedAnswer: prefersDetailedAnswer,
            requestedFacets: requestedFacets(for: lowered)
        )
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
                detailLevel: queryProfile.prefersDetailedAnswer ? .detailed : detailLevel
            ),
            usage: nil
        )
    }

    func defaultPlanSteps(
        for question: String,
        requestOptions: MemoryQueryOptions,
        profile: QueryIntentProfile
    ) -> [MemoryQueryPlanStep] {
        let plannedQueries = plannerQueries(for: question, profile: profile)
        let queries = plannedQueries.isEmpty ? [question] : plannedQueries

        var steps: [MemoryQueryPlanStep] = []
        let researchLimit = profile.prefersDetailedAnswer ? 8 : 6
        let evidenceLimit = profile.prefersDetailedAnswer ? 8 : (profile.prefersLexicalFirst ? 6 : 5)
        let researchCount = profile.prefersDetailedAnswer ? 3 : 2
        let evidenceCount = profile.prefersDetailedAnswer ? 6 : 4

        if profile.prefersLexicalFirst && requestOptions.includesLexicalSearch {
            for query in queries.prefix(researchCount) {
                steps.append(
                    MemoryQueryPlanStep(
                        query: query,
                        sources: [.bm25Store],
                        phase: .research,
                        maxResults: researchLimit
                    )
                )
            }
        }

        for query in queries.prefix(evidenceCount) {
            var sources = requestOptions.sources
            if profile.prefersLexicalFirst && requestOptions.includesLexicalSearch {
                sources.insert(.bm25Store)
            }

            steps.append(
                MemoryQueryPlanStep(
                    query: query,
                    sources: sources,
                    phase: .evidence,
                    maxResults: evidenceLimit
                )
            )
        }

        return steps
    }

    private func plannerQueries(for question: String, profile: QueryIntentProfile) -> [String] {
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

        let anchorTokens = anchorTokens(from: tokens)
        let anchorQuery = Array(anchorTokens.prefix(profile.prefersDetailedAnswer ? 3 : 2)).joined(separator: " ")
        add(anchorQuery)

        if profile.prefersDetailedAnswer {
            for facet in profile.requestedFacets {
                add([anchorQuery, facet].filter { !$0.isEmpty }.joined(separator: " "))
            }
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

        return Array(queries.prefix(profile.prefersDetailedAnswer ? 8 : 6))
    }

    private func requestedFacets(for loweredQuestion: String) -> [String] {
        var facets: [String] = []
        if loweredQuestion.contains("project") {
            facets.append("projects")
        }
        if loweredQuestion.contains("task") {
            facets.append("tasks")
        }
        if loweredQuestion.contains("takeaway") || loweredQuestion.contains("learning") {
            facets.append("takeaways")
        }
        if loweredQuestion.contains("struggle") || loweredQuestion.contains("blocker") || loweredQuestion.contains("problem") {
            facets.append("blockers")
        }
        if loweredQuestion.contains("question") {
            facets.append("questions answered")
        }
        if loweredQuestion.contains("strength") {
            facets.append("strengths")
        }
        if loweredQuestion.contains("weakness") {
            facets.append("weaknesses")
        }
        if loweredQuestion.contains("fit") || loweredQuestion.contains("match") || loweredQuestion.contains("level") {
            facets.append("fit")
        }
        return facets
    }

    private func anchorTokens(from tokens: [String]) -> [String] {
        let facetTokens: Set<String> = [
            "project", "projects", "task", "tasks", "takeaway", "takeaways",
            "learning", "learnings", "struggle", "struggles", "blocker", "blockers",
            "problem", "problems", "summary", "summarize", "timeline"
        ]
        let filtered = tokens.filter { !facetTokens.contains($0) }
        return filtered.isEmpty ? tokens : filtered
    }
}
