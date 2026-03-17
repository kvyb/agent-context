import Foundation

struct MemoryQueryFallbackAnswerBuilder: Sendable {
    private let calendar: Calendar

    init(calendar: Calendar = .autoupdatingCurrent) {
        self.calendar = calendar
    }

    func build(
        question: String,
        scopeLabel: String?,
        detailLevel: MemoryQueryDetailLevel,
        mem0Evidence: [MemoryEvidenceHit],
        bm25Evidence: [MemoryEvidenceHit]
    ) -> MemoryQueryAnswerPayload {
        let combinedEvidence = combinedEvidence(
            mem0Evidence: mem0Evidence,
            bm25Evidence: bm25Evidence
        )
        let evidenceLimit = detailLevel == .detailed ? 8 : 5
        let topEvidence = Array(combinedEvidence.prefix(evidenceLimit))
        let scopedSuffix = scopeLabel?.nilIfEmpty.map { " for \($0)" } ?? ""
        let sourceSummary = sourceSummary(
            mem0Count: mem0Evidence.count,
            bm25Count: bm25Evidence.count
        )

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

    private func combinedEvidence(
        mem0Evidence: [MemoryEvidenceHit],
        bm25Evidence: [MemoryEvidenceHit]
    ) -> [MemoryEvidenceHit] {
        let ordered = (bm25Evidence + mem0Evidence).sorted { lhs, rhs in
            let lhsScore = sourceScore(lhs)
            let rhsScore = sourceScore(rhs)
            if abs(lhsScore - rhsScore) > 0.0001 {
                return lhsScore > rhsScore
            }
            if lhs.source != rhs.source {
                return lhs.source == .bm25Store
            }
            return (lhs.occurredAt ?? .distantPast) > (rhs.occurredAt ?? .distantPast)
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

    private func sourceScore(_ hit: MemoryEvidenceHit) -> Double {
        switch hit.source {
        case .mem0Semantic:
            return hit.semanticScore
        case .bm25Store:
            return hit.hybridScore
        }
    }

    private func sourceSummary(mem0Count: Int, bm25Count: Int) -> String {
        var parts: [String] = []
        if bm25Count > 0 {
            parts.append("BM25 storage (\(bm25Count))")
        }
        if mem0Count > 0 {
            parts.append("semantic memory (\(mem0Count))")
        }
        if parts.isEmpty {
            return "the enabled memory sources"
        }
        return naturalLanguageJoin(parts)
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

        let joinedEvidence = evidence.map { $0.text.lowercased() }.joined(separator: "\n")
        let transcriptIndicators = ["transcript", "verbatim", "speaker", "utterance"]
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
}
