import Foundation

struct MemoryQueryEvidenceSelection: Sendable {
    static func prioritizedSubset(
        from orderedEvidence: [MemoryEvidenceHit],
        limit: Int,
        detailLevel: MemoryQueryDetailLevel,
        analysis: MemoryQueryQuestionAnalysis,
        scope: MemoryQueryScope? = nil
    ) -> [MemoryEvidenceHit] {
        let cappedLimit = max(0, min(limit, orderedEvidence.count))
        guard cappedLimit > 0 else { return [] }
        guard shouldDiversify(orderedEvidence, analysis: analysis, scope: scope) else {
            return Array(orderedEvidence.prefix(cappedLimit))
        }

        var remaining = Array(orderedEvidence.enumerated())
        var selected: [(offset: Int, element: MemoryEvidenceHit)] = []
        var dayCounts: [String: Int] = [:]
        var appCounts: [String: Int] = [:]
        var projectCounts: [String: Int] = [:]
        var unitCounts: [String: Int] = [:]

        while selected.count < cappedLimit, !remaining.isEmpty {
            var bestPosition = 0
            var bestScore = -Double.greatestFiniteMagnitude

            for (position, candidate) in remaining.enumerated() {
                let score = selectionScore(
                    candidate,
                    selectedCount: selected.count,
                    dayCounts: dayCounts,
                    appCounts: appCounts,
                    projectCounts: projectCounts,
                    unitCounts: unitCounts
                )
                if score > bestScore {
                    bestScore = score
                    bestPosition = position
                }
            }

            let chosen = remaining.remove(at: bestPosition)
            selected.append(chosen)

            if let dayKey = dayKey(for: chosen.element) {
                dayCounts[dayKey, default: 0] += 1
            }
            if let appKey = normalizedKey(chosen.element.appName) {
                appCounts[appKey, default: 0] += 1
            }
            if let projectKey = normalizedKey(chosen.element.project ?? chosen.element.metadata["project"]) {
                projectCounts[projectKey, default: 0] += 1
            }
            if let unitKey = retrievalUnitKey(for: chosen.element) {
                unitCounts[unitKey, default: 0] += 1
            }
        }

        let selectedHits = selected.map(\.element)
        if detailLevel == .detailed {
            return selectedHits.sorted { ($0.occurredAt ?? .distantPast) < ($1.occurredAt ?? .distantPast) }
        }
        return selectedHits
    }

    private static func shouldDiversify(
        _ evidence: [MemoryEvidenceHit],
        analysis: MemoryQueryQuestionAnalysis,
        scope: MemoryQueryScope?
    ) -> Bool {
        guard analysis.seeksWorkSummary else { return false }
        guard !analysis.prefersLexicalFirst else { return false }
        guard evidence.count > 6 else { return false }

        if let start = scope?.start, let end = scope?.end,
           end.timeIntervalSince(start) >= 36 * 3600 {
            return true
        }

        return Set(evidence.compactMap(dayKey)).count >= 2
    }

    private static func selectionScore(
        _ candidate: (offset: Int, element: MemoryEvidenceHit),
        selectedCount: Int,
        dayCounts: [String: Int],
        appCounts: [String: Int],
        projectCounts: [String: Int],
        unitCounts: [String: Int]
    ) -> Double {
        let offset = candidate.offset
        let hit = candidate.element

        var score = 100.0 - Double(offset * 3)
        if offset < max(3, selectedCount + 1) {
            score += 8
        }

        if let dayKey = dayKey(for: hit) {
            score += dayCounts[dayKey] == nil ? 24 : -(Double(dayCounts[dayKey, default: 0]) * 10)
        }
        if let appKey = normalizedKey(hit.appName) {
            score += appCounts[appKey] == nil ? 12 : -(Double(appCounts[appKey, default: 0]) * 5)
        }
        if let projectKey = normalizedKey(hit.project ?? hit.metadata["project"]) {
            score += projectCounts[projectKey] == nil ? 6 : -(Double(projectCounts[projectKey, default: 0]) * 2.5)
        }
        if let unitKey = retrievalUnitKey(for: hit) {
            score += unitCounts[unitKey] == nil ? 10 : -(Double(unitCounts[unitKey, default: 0]) * 4)
        }

        return score
    }

    private static func dayKey(for hit: MemoryEvidenceHit) -> String? {
        guard let occurredAt = hit.occurredAt else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: occurredAt)
    }

    private static func normalizedKey(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfEmpty
    }

    private static func retrievalUnitKey(for hit: MemoryEvidenceHit) -> String? {
        normalizedKey(hit.metadata["retrieval_unit"] ?? hit.metadata["scope"])
    }
}
