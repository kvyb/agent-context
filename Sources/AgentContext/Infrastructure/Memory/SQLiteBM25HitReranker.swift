import Foundation

struct SQLiteBM25HitReranker: Sendable {
    func rerankedLexicalHits(
        _ hits: [MemoryEvidenceHit],
        analysis: MemoryQueryQuestionAnalysis,
        limit: Int
    ) -> [MemoryEvidenceHit] {
        let sorted = hits
            .sorted { lhs, rhs in
                let lhsScore = rerankScore(lhs, analysis: analysis)
                let rhsScore = rerankScore(rhs, analysis: analysis)
                if abs(lhsScore - rhsScore) > 0.0001 {
                    return lhsScore > rhsScore
                }
                return lexicalHitSort(lhs, rhs)
            }
        return diversifiedHits(sorted, analysis: analysis, limit: limit)
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
        if analysis.seeksCallConversation {
            let isZoomScoped = isZoomScoped(metadata: metadata, text: loweredText)
            let peopleText = [metadata["people"], metadata["entities"]]
                .compactMap { $0?.nilIfEmpty }
                .joined(separator: " ")
                .lowercased()

            if unit == .transcriptUnit || unit == .transcriptChunk {
                if isZoomScoped {
                    boost += 0.42
                }
                if analysis.focusTerms.contains(where: { peopleText.contains($0) }) {
                    boost += 0.32
                }
            } else if unit == .taskSegment {
                boost -= isZoomScoped ? 0.08 : 0.58
            } else {
                boost -= isZoomScoped ? 0.12 : 0.68
            }
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
        if analysis.seeksWorkSummary, analysis.focusTerms.isEmpty {
            switch unit {
            case .taskSegment:
                score += 0.7
            case .memorySummary:
                score += 0.45
            case .artifactEvidence:
                score -= 0.2
            case .transcriptChunk, .transcriptUnit:
                score -= 0.05
            }
        }
        if analysis.seeksCallConversation {
            let isZoomScoped = isZoomScoped(metadata: hit.metadata, text: evidenceText(hit))
            if unit == .transcriptUnit || unit == .transcriptChunk {
                score += isZoomScoped ? 0.9 : 0.25
            } else if unit == .artifactEvidence {
                score += isZoomScoped ? 0.1 : -0.75
            } else if unit == .taskSegment {
                if analysis.personTerms.isEmpty {
                    score += isZoomScoped ? 0.45 : -0.95
                } else {
                    score += isZoomScoped ? -0.2 : -0.95
                }
            } else {
                if analysis.personTerms.isEmpty {
                    score += isZoomScoped ? 0.2 : -0.85
                } else {
                    score -= 0.85
                }
            }
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
        score += recencyBoost(for: hit, analysis: analysis)
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

    private func diversifiedHits(
        _ hits: [MemoryEvidenceHit],
        analysis: MemoryQueryQuestionAnalysis,
        limit: Int
    ) -> [MemoryEvidenceHit] {
        guard limit > 0 else {
            return []
        }

        let deduplicated = hits.reduce(into: [MemoryEvidenceHit]()) { acc, hit in
            guard !acc.contains(where: { $0.id == hit.id }) else { return }
            acc.append(hit)
        }
        let repetitionCap = preferredRepetitionCap(for: analysis)
        guard repetitionCap < Int.max else {
            return Array(deduplicated.prefix(limit))
        }

        var output: [MemoryEvidenceHit] = []
        var seenIDs = Set<String>()
        var diversityCounts: [String: Int] = [:]

        func tryAppend(_ hit: MemoryEvidenceHit, strict: Bool) {
            guard output.count < limit else { return }
            guard seenIDs.insert(hit.id).inserted else { return }
            let key = diversityKey(for: hit, analysis: analysis)
            if strict, let key, diversityCounts[key, default: 0] >= repetitionCap {
                seenIDs.remove(hit.id)
                return
            }
            output.append(hit)
            if let key {
                diversityCounts[key, default: 0] += 1
            }
        }

        for hit in deduplicated {
            tryAppend(hit, strict: true)
        }
        if output.count < limit {
            for hit in deduplicated {
                tryAppend(hit, strict: false)
            }
        }

        return output
    }

    private func preferredRepetitionCap(for analysis: MemoryQueryQuestionAnalysis) -> Int {
        if analysis.seeksCallConversation {
            return 1
        }
        if analysis.seeksWorkSummary, analysis.focusTerms.isEmpty {
            return 1
        }
        if analysis.seeksWorkSummary {
            return 2
        }
        return .max
    }

    private func diversityKey(
        for hit: MemoryEvidenceHit,
        analysis: MemoryQueryQuestionAnalysis
    ) -> String? {
        if analysis.seeksCallConversation {
            if let session = hit.metadata["session_id"]?.nilIfEmpty {
                return "session|\(session.lowercased())"
            }
            let timeBucket = hit.occurredAt.map { Int($0.timeIntervalSince1970 / 1800) } ?? -1
            let medium = (hit.appName?.nilIfEmpty ?? hit.metadata["app_name"]?.nilIfEmpty ?? "unknown").lowercased()
            return "call|\(medium)|\(timeBucket)"
        }

        if analysis.seeksWorkSummary {
            if let project = hit.project?.nilIfEmpty ?? hit.metadata["project"]?.nilIfEmpty {
                return "project|\(project.lowercased())"
            }
            if let appName = hit.appName?.nilIfEmpty ?? hit.metadata["app_name"]?.nilIfEmpty {
                return "app|\(appName.lowercased())"
            }
            let timeBucket = hit.occurredAt.map { Int($0.timeIntervalSince1970 / 1800) } ?? -1
            return "time|\(timeBucket)"
        }

        return nil
    }

    private func recencyBoost(
        for hit: MemoryEvidenceHit,
        analysis: MemoryQueryQuestionAnalysis
    ) -> Double {
        guard let occurredAt = hit.occurredAt else {
            return 0
        }

        let ageHours = max(0, Date().timeIntervalSince(occurredAt) / 3600)
        if analysis.seeksWorkSummary {
            if ageHours < 3 { return 0.7 }
            if ageHours < 12 { return 0.45 }
            if ageHours < 24 { return 0.28 }
            if ageHours < 72 { return 0.12 }
            return 0
        }
        if analysis.seeksCallConversation {
            if ageHours < 6 { return 0.45 }
            if ageHours < 24 { return 0.22 }
            return 0
        }
        return 0
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

    private func isZoomScoped(metadata: [String: String], text: String) -> Bool {
        let joined = (
            text
            + " "
            + metadata.values.joined(separator: " ")
        ).lowercased()
        return joined.contains("zoom")
            || joined.contains("zoom.us")
            || joined.contains("video conference")
            || joined.contains("meeting")
            || joined.contains("call")
    }
}
