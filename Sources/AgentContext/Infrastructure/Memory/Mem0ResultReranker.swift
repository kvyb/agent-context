import Foundation

struct Mem0ResultReranker: Sendable {
    private let scopeParser: MemoryQueryScopeParser
    private let questionAnalyzer: MemoryQueryQuestionAnalyzer
    private let transcriptIndicators = ["transcript", "interview", "meeting", "zoom", "call", "candidate", "notetaker"]
    private let blockerIndicators = ["blocked", "blocker", "issue", "error", "failed", "timeout", "stuck"]
    private let metaNoiseIndicators = ["remind me", "later analysis", "follow up later", "analyze later", "todo", "later"]

    init(scopeParser: MemoryQueryScopeParser = MemoryQueryScopeParser()) {
        self.scopeParser = scopeParser
        self.questionAnalyzer = MemoryQueryQuestionAnalyzer(scopeParser: scopeParser)
    }

    func rerank(
        hits: [Mem0SearchHit],
        queries: [String],
        scope: MemoryQueryScope,
        limit: Int
    ) -> [MemoryEvidenceHit] {
        let combinedQuestion = queries.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let queryTerms = scopeParser.queryTerms(for: combinedQuestion)
        let analysis = questionAnalyzer.analyze(question: combinedQuestion)
        let total = max(1, hits.count)
        let maxRawScore = max(hits.compactMap(\.score).max() ?? 0, 0.000_1)

        var merged: [String: MemoryEvidenceHit] = [:]

        for (index, hit) in hits.enumerated() {
            let text = hit.memory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let rawSemanticScore: Double
            if let rawScore = hit.score, rawScore > 0 {
                rawSemanticScore = min(1, max(0, rawScore / maxRawScore))
            } else {
                rawSemanticScore = 1.0 - (Double(index) / Double(total))
            }

            var metadata = hit.metadata.reduce(into: [String: String]()) { acc, pair in
                if let value = pair.value.nilIfEmpty {
                    acc[pair.key] = value
                }
            }
            metadata["retrieval_unit"] = "mem0_semantic"
            if let rawScore = hit.score {
                metadata["mem0_raw_score"] = String(format: "%.4f", rawScore)
            }

            let queryMatchScore = lexicalAlignmentScore(
                queryTerms: queryTerms,
                text: searchableText(for: hit, metadata: metadata)
            )
            let boost = metadataMatchBoost(
                hit: hit,
                metadata: metadata,
                analysis: analysis,
                scope: scope,
                queryMatchScore: queryMatchScore
            )
            let finalScore = rawSemanticScore + boost

            metadata["mem0_query_match_score"] = String(format: "%.3f", queryMatchScore)
            metadata["mem0_domain_boost"] = String(format: "%.3f", boost)
            metadata["mem0_final_score"] = String(format: "%.3f", finalScore)

            let timeKey = hit.occurredAt.map { Int($0.timeIntervalSince1970 / 30) } ?? 0
            let key = "mem0|\(timeKey)|\(text.prefix(160).lowercased())"
            if let existing = merged[key], existing.semanticScore >= finalScore {
                continue
            }

            merged[key] = MemoryEvidenceHit(
                id: key,
                source: .mem0Semantic,
                text: text,
                appName: hit.appName?.nilIfEmpty,
                project: hit.project?.nilIfEmpty,
                occurredAt: hit.occurredAt,
                metadata: metadata,
                semanticScore: finalScore,
                lexicalScore: queryMatchScore,
                hybridScore: finalScore
            )
        }

        return merged.values
            .sorted { lhs, rhs in
                if abs(lhs.semanticScore - rhs.semanticScore) > 0.0001 {
                    return lhs.semanticScore > rhs.semanticScore
                }
                if abs(lhs.lexicalScore - rhs.lexicalScore) > 0.0001 {
                    return lhs.lexicalScore > rhs.lexicalScore
                }
                return (lhs.occurredAt ?? .distantPast) > (rhs.occurredAt ?? .distantPast)
            }
            .prefix(limit)
            .map { $0 }
    }

    private func metadataMatchBoost(
        hit: Mem0SearchHit,
        metadata: [String: String],
        analysis: MemoryQueryQuestionAnalysis,
        scope: MemoryQueryScope,
        queryMatchScore: Double
    ) -> Double {
        let searchableText = searchableText(for: hit, metadata: metadata)
        var score = queryMatchScore * 0.28

        if !analysis.focusTerms.isEmpty {
            let focusMatches = analysis.focusTerms.filter { searchableText.contains($0.lowercased()) }.count
            score += min(0.32, Double(focusMatches) * 0.12)
        }

        if let project = hit.project?.lowercased(), analysis.focusTerms.contains(where: { project.contains($0.lowercased()) }) {
            score += 0.2
        }
        if let appName = hit.appName?.lowercased(), analysis.focusTerms.contains(where: { appName.contains($0.lowercased()) }) {
            score += 0.12
        }

        if analysis.prefersLexicalFirst {
            if containsAny(of: transcriptIndicators, in: searchableText) {
                score += 0.28
            } else {
                score -= 0.12
            }
        }

        if analysis.seeksEvaluation {
            if containsAny(of: transcriptIndicators, in: searchableText) {
                score += 0.16
            }
            if containsAny(of: blockerIndicators, in: searchableText) {
                score -= 0.04
            }
        }

        if analysis.seeksWorkSummary {
            let scopeValue = metadata["scope"]?.lowercased() ?? ""
            if scopeValue.contains("task") || scopeValue.contains("session") {
                score += 0.18
            }
            if let categories = metadata["categories"]?.lowercased(), categories.contains("work") {
                score += 0.08
            }
        }

        if analysis.requestedDimensions.contains("blockers") {
            if containsAny(of: blockerIndicators, in: searchableText) {
                score += 0.18
            } else {
                score -= 0.05
            }
        }

        if let occurredAt = hit.occurredAt, let start = scope.start, let end = scope.end {
            if occurredAt >= start && occurredAt < end {
                score += 0.08
            }
        } else if scope.start != nil || scope.end != nil {
            score -= 0.08
        }

        if isMetaNoise(searchableText) {
            score -= 0.32
        }

        return score
    }

    private func lexicalAlignmentScore(queryTerms: [String], text: String) -> Double {
        guard !queryTerms.isEmpty else { return 0 }
        let lowered = text.lowercased()
        let matches = queryTerms.filter { lowered.contains($0.lowercased()) }.count
        guard matches > 0 else { return 0 }
        return min(1, Double(matches) / Double(queryTerms.count))
    }

    private func searchableText(for hit: Mem0SearchHit, metadata: [String: String]) -> String {
        [
            hit.memory,
            hit.project,
            hit.appName,
            metadata["entities"],
            metadata["categories"],
            metadata["scope"],
            metadata["retrieved_query"]
        ]
        .compactMap { $0?.nilIfEmpty }
        .joined(separator: " | ")
        .lowercased()
    }

    private func containsAny(of needles: [String], in text: String) -> Bool {
        needles.contains { text.contains($0) }
    }

    private func isMetaNoise(_ text: String) -> Bool {
        containsAny(of: metaNoiseIndicators, in: text)
    }
}
