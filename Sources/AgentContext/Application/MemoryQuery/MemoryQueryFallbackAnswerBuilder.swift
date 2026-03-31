import Foundation

struct MemoryQueryFallbackAnswerBuilder: Sendable {
    private let calendar: Calendar
    private let questionAnalyzer: MemoryQueryQuestionAnalyzer
    private let transcriptIndicators = ["transcript", "verbatim", "speaker", "utterance", "artifact_kind"]

    init(calendar: Calendar = .autoupdatingCurrent) {
        self.calendar = calendar
        self.questionAnalyzer = MemoryQueryQuestionAnalyzer(
            scopeParser: MemoryQueryScopeParser(calendar: calendar)
        )
    }

    func build(
        question: String,
        scopeLabel: String?,
        detailLevel: MemoryQueryDetailLevel,
        mem0Evidence: [MemoryEvidenceHit],
        fullContextMode: Bool = false
    ) -> MemoryQueryAnswerPayload {
        let analysis = questionAnalyzer.analyze(question: question)
        let combinedEvidence = deduplicatedEvidence(mem0Evidence)

        if let dimensionAwareAnswer = buildDimensionAwareAnswer(
            question: question,
            scopeLabel: scopeLabel,
            detailLevel: detailLevel,
            analysis: analysis,
            evidence: combinedEvidence,
            fullContextMode: fullContextMode
        ) {
            return dimensionAwareAnswer
        }

        let evidenceLimit: Int
        if fullContextMode {
            evidenceLimit = detailLevel == .detailed ? 14 : 8
        } else {
            evidenceLimit = detailLevel == .detailed ? 8 : 5
        }
        let topEvidence = MemoryQueryEvidenceSelection.prioritizedSubset(
            from: combinedEvidence,
            limit: evidenceLimit,
            detailLevel: detailLevel,
            analysis: analysis
        )
        let scopedSuffix = scopeLabel?.nilIfEmpty.map { " for \($0)" } ?? ""
        let sourceSummary = sourceSummary(mem0Count: mem0Evidence.count)

        var paragraphs: [String] = [
            "For \"\(question)\", I found \(combinedEvidence.count) relevant memory hit\(combinedEvidence.count == 1 ? "" : "s")\(scopedSuffix) across \(sourceSummary)."
        ]

        let highlightCount = detailLevel == .detailed ? 3 : 2
        let highlightClauses = topEvidence.prefix(highlightCount).map(evidenceClause)
        if !highlightClauses.isEmpty {
            paragraphs.append("The strongest retrieved evidence points to \(naturalLanguageJoin(highlightClauses)).")
        }

        if shouldMentionTranscriptGap(question: question, evidence: topEvidence) {
            paragraphs.append("I found meeting and interview records related to the request, but I did not find a verbatim transcript in the retrieved evidence.")
        } else if topEvidence.count == 1 {
            paragraphs.append("This answer is based on a small amount of fallback evidence, so it should be treated as directional rather than exhaustive.")
        }

        return MemoryQueryAnswerPayload(
            answer: paragraphs.joined(separator: "\n\n"),
            keyPoints: keyPoints(from: topEvidence, detailLevel: detailLevel),
            supportingEvents: topEvidence.map(supportingEventLine),
            insufficientEvidence: true
        )
    }

    private func buildDimensionAwareAnswer(
        question: String,
        scopeLabel: String?,
        detailLevel: MemoryQueryDetailLevel,
        analysis: MemoryQueryQuestionAnalysis,
        evidence: [MemoryEvidenceHit],
        fullContextMode: Bool
    ) -> MemoryQueryAnswerPayload? {
        guard !analysis.requestedDimensions.isEmpty || analysis.seeksEvaluation else {
            return nil
        }
        let rankedEvidence = rankEvidence(
            evidence,
            analysis: analysis,
            loweredQuestion: question.lowercased()
        )
        guard !rankedEvidence.isEmpty else {
            return nil
        }

        let evidenceLimit: Int
        if fullContextMode {
            evidenceLimit = detailLevel == .detailed ? 20 : 12
        } else {
            evidenceLimit = detailLevel == .detailed ? 14 : 8
        }
        let topEvidence = MemoryQueryEvidenceSelection.prioritizedSubset(
            from: rankedEvidence,
            limit: evidenceLimit,
            detailLevel: detailLevel,
            analysis: analysis
        )
        let dimensionLimit = detailLevel == .detailed ? 6 : 4
        var dimensionSections: [String] = []
        var dimensionKeyPoints: [String] = []
        var coveredDimensions = 0

        for dimension in analysis.requestedDimensions.prefix(dimensionLimit) {
            let bullets = dimensionBullets(
                for: dimension,
                from: topEvidence,
                analysis: analysis,
                detailLevel: detailLevel
            )
            guard !bullets.isEmpty else { continue }
            coveredDimensions += 1
            dimensionSections.append(section(title: dimensionTitle(dimension), bullets: bullets))
            dimensionKeyPoints.append(contentsOf: bullets)
        }

        let scopedSuffix = scopeLabel?.nilIfEmpty.map { " for \($0)" } ?? ""
        let sourceSummary = sourceSummary(mem0Count: evidence.count)
        let assessment = provisionalAssessment(
            question: question,
            evidence: topEvidence,
            analysis: analysis
        )
        var summary = "For \"\(question)\", I found \(topEvidence.count) strongly relevant memory hit\(topEvidence.count == 1 ? "" : "s")\(scopedSuffix) across \(sourceSummary)."
        if let assessment {
            summary += " \(assessment)"
        }
        if !analysis.focusTerms.isEmpty {
            summary += " The strongest evidence stays centered on \(naturalLanguageJoin(analysis.focusTerms.prefix(3).map { "\"\($0)\"" }))."
        }

        var paragraphs: [String] = [summary]
        if !dimensionSections.isEmpty {
            paragraphs.append(contentsOf: dimensionSections)
        }
        if fullContextMode {
            paragraphs.append("The retrieved evidence appears to cover a narrowly scoped corpus, so this answer uses the full local record rather than only a few top hits.")
        }
        if shouldMentionTranscriptGap(question: question, evidence: topEvidence) {
            paragraphs.append("I found related interview or meeting evidence, but not enough direct transcript content to fully answer every requested dimension.")
        }

        let keyPoints = Array(
            uniqueStrings(
                dimensionKeyPoints + (assessment.map { [$0] } ?? []) + keyPoints(from: topEvidence, detailLevel: detailLevel)
            )
            .prefix(detailLevel == .detailed ? 12 : 8)
        )
        let requiredCoverage = max(1, analysis.requestedDimensions.count / 2)
        let insufficientEvidence = topEvidence.count < 2
            || (!analysis.requestedDimensions.isEmpty && coveredDimensions < requiredCoverage)

        return MemoryQueryAnswerPayload(
            answer: paragraphs.joined(separator: "\n\n"),
            keyPoints: keyPoints,
            supportingEvents: topEvidence.map(supportingEventLine),
            insufficientEvidence: insufficientEvidence
        )
    }

    private func deduplicatedEvidence(_ evidence: [MemoryEvidenceHit]) -> [MemoryEvidenceHit] {
        let ordered = evidence.sorted {
            if abs($0.semanticScore - $1.semanticScore) > 0.0001 {
                return $0.semanticScore > $1.semanticScore
            }
            return ($0.occurredAt ?? .distantPast) > ($1.occurredAt ?? .distantPast)
        }

        var seen = Set<String>()
        var deduplicated: [MemoryEvidenceHit] = []
        for hit in ordered {
            let key = evidenceDedupKey(hit)
            guard seen.insert(key).inserted else { continue }
            deduplicated.append(hit)
        }
        return deduplicated
    }

    private func sourceSummary(mem0Count: Int) -> String {
        mem0Count > 0 ? "Mem0 (\(mem0Count))" : "Mem0"
    }

    private func evidenceClause(_ hit: MemoryEvidenceHit) -> String {
        var context: [String] = []
        if let occurredAt = hit.occurredAt {
            context.append("on \(timestamp(occurredAt))")
        }
        if let appName = hit.appName?.nilIfEmpty {
            context.append("in \(appName)")
        }
        if let project = (hit.project?.nilIfEmpty ?? hit.metadata["project"]?.nilIfEmpty) {
            context.append("for \(project)")
        }

        let contextPrefix = context.isEmpty ? "an entry" : "an entry " + context.joined(separator: " ")
        return "\(contextPrefix) describing \(condensedSnippet(hit.text, maxLength: 160))"
    }

    private func keyPoints(
        from evidence: [MemoryEvidenceHit],
        detailLevel: MemoryQueryDetailLevel
    ) -> [String] {
        let limit = detailLevel == .detailed ? 8 : 4
        var seen = Set<String>()
        var points: [String] = []

        for hit in evidence {
            let snippet = condensedSnippet(hit.text, maxLength: detailLevel == .detailed ? 200 : 140)
            let key = snippet.lowercased()
            guard seen.insert(key).inserted else { continue }
            points.append(snippet)
            if points.count >= limit {
                break
            }
        }

        return points
    }

    private func supportingEventLine(_ hit: MemoryEvidenceHit) -> String {
        let timestampText = hit.occurredAt.map(timestamp) ?? "unknown time"
        let appName = hit.appName?.nilIfEmpty ?? "unknown app"
        return "[\(timestampText)] \(appName): \(condensedSnippet(hit.text, maxLength: 140))"
    }

    private func shouldMentionTranscriptGap(question: String, evidence: [MemoryEvidenceHit]) -> Bool {
        let loweredQuestion = question.lowercased()
        guard loweredQuestion.contains("transcript") else {
            return false
        }

        let joinedEvidence = evidence.map {
            ($0.text + "\n" + $0.metadata.values.joined(separator: " ")).lowercased()
        }.joined(separator: "\n")
        return !transcriptIndicators.contains { joinedEvidence.contains($0) }
    }

    private func evidenceDedupKey(_ hit: MemoryEvidenceHit) -> String {
        let timestampBucket: String
        if let occurredAt = hit.occurredAt {
            timestampBucket = String(Int(occurredAt.timeIntervalSince1970 / 300))
        } else {
            timestampBucket = "no-time"
        }
        let snippet = condensedSnippet(hit.text, maxLength: 120).lowercased()
        return "\(timestampBucket)|\(snippet)"
    }

    private func condensedSnippet(_ text: String, maxLength: Int) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(
                of: "\\s+",
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard collapsed.count > maxLength else {
            return collapsed
        }

        let cutoff = collapsed.index(collapsed.startIndex, offsetBy: maxLength)
        let prefix = String(collapsed[..<cutoff])
        if let lastSpace = prefix.lastIndex(of: " ") {
            let trimmed = String(prefix[..<lastSpace])
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            return trimmed + "..."
        }

        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return trimmed + "..."
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func naturalLanguageJoin(_ items: [String]) -> String {
        switch items.count {
        case 0:
            return ""
        case 1:
            return items[0]
        case 2:
            return "\(items[0]) and \(items[1])"
        default:
            let head = items.dropLast().joined(separator: ", ")
            return "\(head), and \(items.last ?? "")"
        }
    }

    private func rankEvidence(
        _ evidence: [MemoryEvidenceHit],
        analysis: MemoryQueryQuestionAnalysis,
        loweredQuestion: String
    ) -> [MemoryEvidenceHit] {
        evidence.sorted { lhs, rhs in
            let lhsScore = queryRelevanceScore(lhs, analysis: analysis, loweredQuestion: loweredQuestion)
            let rhsScore = queryRelevanceScore(rhs, analysis: analysis, loweredQuestion: loweredQuestion)
            if abs(lhsScore - rhsScore) > 0.0001 {
                return lhsScore > rhsScore
            }
            return (lhs.occurredAt ?? .distantPast) > (rhs.occurredAt ?? .distantPast)
        }
    }

    private func queryRelevanceScore(
        _ hit: MemoryEvidenceHit,
        analysis: MemoryQueryQuestionAnalysis,
        loweredQuestion: String
    ) -> Double {
        var score = sourceScore(hit)
        let loweredText = evidenceText(hit)
        let retrievalUnit = hit.metadata["retrieval_unit"] ?? ""
        let structuralText = [
            hit.project?.nilIfEmpty,
            hit.metadata["project"]?.nilIfEmpty,
            hit.metadata["repo"]?.nilIfEmpty,
            hit.metadata["workspace"]?.nilIfEmpty,
            hit.metadata["task"]?.nilIfEmpty
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()

        if analysis.prefersLexicalFirst && isDirectTranscriptEvidence(hit) {
            score += 1.8
        }
        if loweredQuestion.contains("transcript"), isDirectTranscriptEvidence(hit) {
            score += 0.8
        }
        if analysis.seeksWorkSummary {
            if retrievalUnit == "task_segment" {
                score += 0.55
            } else if retrievalUnit == "artifact_evidence" {
                score += 0.08
            }
        }
        if analysis.prefersLexicalFirst,
           loweredQuestion.contains("transcript"),
           !isDirectTranscriptEvidence(hit),
           (loweredText.contains("telegram") || loweredText.contains("tulpa") || loweredText.contains("analyze")) {
            score -= 1.35
        }

        var matchedFocusTerms = 0
        var structuralFocusMatches = 0
        for term in analysis.focusTerms {
            if structuralText.contains(term) {
                matchedFocusTerms += 1
                structuralFocusMatches += 1
                score += term.count >= 5 ? 0.6 : 0.35
            } else if loweredText.contains(term) {
                matchedFocusTerms += 1
                score += term.count >= 5 ? 0.45 : 0.25
            }
        }
        if !analysis.focusTerms.isEmpty && matchedFocusTerms == 0 {
            score -= 0.35
        }
        if analysis.seeksWorkSummary,
           !analysis.focusTerms.isEmpty,
           structuralFocusMatches == 0 {
            if retrievalUnit == "artifact_evidence" {
                score -= 0.65
            } else if retrievalUnit == "memory_summary" {
                score -= 0.3
            }
        }

        for dimension in analysis.requestedDimensions {
            let tokens = dimensionTokens(dimension)
            let matches = tokens.filter { loweredText.contains($0) }.count
            score += Double(matches) * 0.18
        }

        if loweredText.contains("telegram reminder") || loweredText.contains("analyze the transcript later") {
            score -= 1.1
        }
        if analysis.seeksEvaluation,
           loweredText.contains("not sure") || loweredText.contains("blocked") || loweredText.contains("risk") {
            score += 0.12
        }
        return score
    }

    private func sourceScore(_ hit: MemoryEvidenceHit) -> Double {
        hit.hybridScore
    }

    private func isDirectTranscriptEvidence(_ hit: MemoryEvidenceHit) -> Bool {
        let retrievalUnit = hit.metadata["retrieval_unit"] ?? ""
        return retrievalUnit == "transcript_unit"
            || (hit.metadata["artifact_kind"] == ArtifactKind.audio.rawValue
                && hit.metadata["has_transcript"] == "true")
    }

    private func dimensionBullets(
        for dimension: String,
        from evidence: [MemoryEvidenceHit],
        analysis: MemoryQueryQuestionAnalysis,
        detailLevel: MemoryQueryDetailLevel
    ) -> [String] {
        let ranked = evidence
            .map { hit in
                (hit, dimensionRelevanceScore(hit, dimension: dimension, analysis: analysis))
            }
            .filter { $0.1 > 0 }
            .sorted {
                if abs($0.1 - $1.1) > 0.0001 {
                    return $0.1 > $1.1
                }
                return ($0.0.occurredAt ?? .distantPast) > ($1.0.occurredAt ?? .distantPast)
            }
            .map(\.0)

        let limit = detailLevel == .detailed ? 3 : 2
        var bullets: [String] = []
        var seen = Set<String>()

        if analysis.seeksEvaluation,
           dimension.contains("fit") || dimension.contains("assessment") || dimension.contains("match"),
           let assessment = provisionalAssessment(question: dimension, evidence: ranked, analysis: analysis) {
            bullets.append(assessment)
            seen.insert(assessment.lowercased())
        }

        for hit in ranked.prefix(limit) {
            let bullet = evidenceBullet(for: hit, dimension: dimension)
            let key = bullet.lowercased()
            guard seen.insert(key).inserted else { continue }
            bullets.append(bullet)
        }

        return bullets
    }

    private func dimensionRelevanceScore(
        _ hit: MemoryEvidenceHit,
        dimension: String,
        analysis: MemoryQueryQuestionAnalysis
    ) -> Double {
        var score = queryRelevanceScore(hit, analysis: analysis, loweredQuestion: dimension)
        let loweredText = evidenceText(hit)
        let tokens = dimensionTokens(dimension)
        for token in tokens where loweredText.contains(token) {
            score += 0.45
        }
        if dimension.contains("strength") || dimension.contains("takeaway") || dimension.contains("decision") {
            score += Double(positiveSignalScore(in: loweredText)) * 0.22
        }
        if dimension.contains("weak") || dimension.contains("struggle") || dimension.contains("blocker") || dimension.contains("risk") {
            score += Double(cautionSignalScore(in: loweredText)) * 0.3
        }
        if dimension.contains("question"), isDirectTranscriptEvidence(hit) {
            score += 0.4
        }
        return score
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

    private func evidenceBullet(for hit: MemoryEvidenceHit, dimension: String) -> String {
        let prefixParts = [
            hit.occurredAt.map(timestamp),
            hit.project?.nilIfEmpty ?? hit.metadata["project"]?.nilIfEmpty,
            hit.appName?.nilIfEmpty
        ].compactMap { $0 }
        let prefix = prefixParts.isEmpty ? "" : "[\(prefixParts.joined(separator: " | "))] "
        return "\(prefix)\(condensedSnippet(hit.text, maxLength: 190))"
    }

    private func provisionalAssessment(
        question: String,
        evidence: [MemoryEvidenceHit],
        analysis: MemoryQueryQuestionAnalysis
    ) -> String? {
        guard analysis.seeksEvaluation else {
            return nil
        }

        let joined = evidence.map(evidenceText).joined(separator: "\n")
        let positiveCount = positiveSignalScore(in: joined)
        let cautionCount = cautionSignalScore(in: joined)

        if positiveCount == 0 && cautionCount == 0 {
            return "The retrieved evidence supports only a limited evaluation, so any judgment should be treated as provisional."
        }
        if positiveCount >= cautionCount + 2 {
            return "The retrieved evidence supports a mostly positive, evidence-backed assessment, with more demonstrated depth than obvious concerns."
        }
        if cautionCount > positiveCount {
            return "The retrieved evidence points to a mixed or cautious assessment, with notable open questions still visible in the record."
        }
        return "The retrieved evidence supports a mixed but directionally positive assessment, with some follow-up still needed on weaker areas."
    }

    private func positiveSignalScore(in loweredText: String) -> Int {
        let signals = [
            "implemented", "shipped", "resolved", "approved", "monitor", "evaluation",
            "trade-off", "vector", "retrieval", "grafana", "ndcg", "design",
            "decision", "architecture", "metrics", "rollout"
        ]
        return signals.filter { loweredText.contains($0) }.count
    }

    private func cautionSignalScore(in loweredText: String) -> Int {
        let signals = [
            "not sure", "unsure", "blocked", "risk", "owner unknown", "follow-up",
            "issue", "bug", "timed out", "unclear", "concern", "limitation", "gap"
        ]
        return signals.filter { loweredText.contains($0) }.count
    }

    private func dimensionTitle(_ dimension: String) -> String {
        dimension
            .split(separator: " ")
            .map { String($0).capitalized }
            .joined(separator: " ")
    }

    private func uniqueStrings(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for item in items {
            let key = item.lowercased()
            guard seen.insert(key).inserted else { continue }
            output.append(item)
        }
        return output
    }

    private func section(title: String, bullets: [String]) -> String {
        let lines = bullets.map { "- \($0)" }.joined(separator: "\n")
        return "\(title):\n\(lines)"
    }
}
