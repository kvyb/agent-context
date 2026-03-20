import Foundation

struct SQLiteBM25HitReranker: Sendable {
    func rerankedLexicalHits(
        _ hits: [MemoryEvidenceHit],
        analysis: MemoryQueryQuestionAnalysis,
        limit: Int
    ) -> [MemoryEvidenceHit] {
        hits
            .sorted { lhs, rhs in
                let lhsScore = rerankScore(lhs, analysis: analysis)
                let rhsScore = rerankScore(rhs, analysis: analysis)
                if abs(lhsScore - rhsScore) > 0.0001 {
                    return lhsScore > rhsScore
                }
                return lexicalHitSort(lhs, rhs)
            }
            .reduce(into: [MemoryEvidenceHit]()) { acc, hit in
                guard !acc.contains(where: { $0.id == hit.id }) else { return }
                acc.append(hit)
            }
            .prefix(limit)
            .map { $0 }
    }

    func metadataMatchBoost(
        text: String,
        metadata: [String: String],
        analysis: MemoryQueryQuestionAnalysis,
        unit: LexicalRetrievalUnit
    ) -> Double {
        let loweredText = text.lowercased()
        let searchableMetadata = metadata.values.joined(separator: " ").lowercased()
        let structuralMetadata = [
            metadata["project"],
            metadata["repo"],
            metadata["workspace"],
            metadata["task"]
        ]
        .compactMap { $0?.nilIfEmpty }
        .joined(separator: " ")
        .lowercased()

        var boost = 0.0
        var focusMatches = 0
        var structuralFocusMatches = 0

        for focus in analysis.focusTerms {
            if structuralMetadata.contains(focus) {
                focusMatches += 1
                structuralFocusMatches += 1
                boost += 0.45
            } else if searchableMetadata.contains(focus) {
                focusMatches += 1
                boost += 0.32
            } else if loweredText.contains(focus) {
                focusMatches += 1
                boost += 0.2
            }
        }

        if !analysis.focusTerms.isEmpty && focusMatches == 0 {
            boost -= unit == .memorySummary ? 0.15 : 0.3
        }
        if analysis.seeksWorkSummary, !analysis.focusTerms.isEmpty, structuralFocusMatches == 0 {
            switch unit {
            case .taskSegment:
                boost -= 0.05
            case .artifactEvidence:
                boost -= 0.35
            case .memorySummary:
                boost -= 0.2
            case .transcriptChunk, .transcriptUnit:
                break
            }
        }

        for dimension in analysis.requestedDimensions {
            let tokens = dimensionTokens(dimension)
            let matches = tokens.filter { loweredText.contains($0) || searchableMetadata.contains($0) }.count
            boost += Double(matches) * 0.08
        }

        if analysis.seeksEvaluation, unit == .transcriptChunk || unit == .transcriptUnit {
            boost += 0.15
        }
        if analysis.seeksEvaluation,
           (unit == .transcriptChunk || unit == .transcriptUnit),
           (loweredText.contains("s1:") || loweredText.contains("s2:")) {
            boost += 0.12
        }
        if analysis.seeksWorkSummary, unit == .taskSegment {
            boost += 0.1
        }

        return boost
    }

    func lexicalHitSort(_ lhs: MemoryEvidenceHit, _ rhs: MemoryEvidenceHit) -> Bool {
        if abs(lhs.hybridScore - rhs.hybridScore) > 0.0001 {
            return lhs.hybridScore > rhs.hybridScore
        }
        return (lhs.occurredAt ?? .distantPast) > (rhs.occurredAt ?? .distantPast)
    }

    private func rerankScore(
        _ hit: MemoryEvidenceHit,
        analysis: MemoryQueryQuestionAnalysis
    ) -> Double {
        var score = hit.hybridScore
        let unit = LexicalRetrievalUnit(rawValue: hit.metadata["retrieval_unit"] ?? "") ?? .memorySummary
        score += corpusBoost(unit: unit, analysis: analysis)

        if analysis.prefersLexicalFirst, unit == .transcriptChunk {
            score += 0.95
        }
        if analysis.prefersLexicalFirst, unit == .transcriptUnit {
            score += 1.15
        }
        if analysis.seeksWorkSummary, unit == .taskSegment {
            score += 0.45
        }
        if analysis.prefersLexicalFirst, unit != .transcriptChunk && unit != .transcriptUnit {
            score -= analysis.seeksEvaluation ? 0.45 : 0.18
        }
        if analysis.seeksEvaluation {
            if unit == .transcriptChunk || unit == .transcriptUnit {
                score += 0.35
            } else if unit == .taskSegment {
                score -= 0.1
            } else {
                score -= 0.3
            }
        }
        if hit.metadata["speaker_turn_window"] == "true" {
            score += 0.15
        }
        if hit.metadata["speaker_exchange"] == "true" {
            score += 0.2
        }
        if isMetaNoise(evidenceText(hit)), analysis.prefersLexicalFirst || analysis.seeksWorkSummary {
            score -= 1.25
        }

        return score
    }

    private func corpusBoost(
        unit: LexicalRetrievalUnit,
        analysis: MemoryQueryQuestionAnalysis
    ) -> Double {
        switch unit {
        case .taskSegment:
            return analysis.seeksWorkSummary ? 0.45 : 0.25
        case .transcriptUnit:
            return analysis.prefersLexicalFirst ? 0.82 : 0.2
        case .transcriptChunk:
            return analysis.prefersLexicalFirst ? 0.6 : 0.15
        case .artifactEvidence:
            return analysis.seeksWorkSummary ? 0.2 : 0.12
        case .memorySummary:
            return 0.05
        }
    }

    private func evidenceText(_ hit: MemoryEvidenceHit) -> String {
        (
            hit.text
            + " "
            + (hit.appName ?? "")
            + " "
            + (hit.project ?? "")
            + " "
            + hit.metadata.values.joined(separator: " ")
        ).lowercased()
    }

    private func dimensionTokens(_ dimension: String) -> [String] {
        dimension
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
    }

    private func isMetaNoise(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return SQLiteBM25Heuristics.metaNoiseIndicators.contains { lowered.contains($0) }
    }
}
