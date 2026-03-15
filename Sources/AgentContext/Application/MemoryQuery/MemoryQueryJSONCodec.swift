import Foundation

struct MemoryQueryJSONCodec: Sendable {
    func parsePlan(from text: String) -> MemoryQueryPlan? {
        guard let object = parseJSONObject(from: text) else { return nil }

        let queries = ((object["queries"] as? [String]) ?? [])
            + ((object["search_queries"] as? [String]) ?? [])

        var start: Date?
        var end: Date?
        var label: String?
        if let timeframe = object["timeframe"] as? [String: Any] {
            start = parseDate(timeframe["start"] as? String)
            end = parseDate(timeframe["end"] as? String)
            label = (timeframe["label"] as? String)?.nilIfEmpty
        } else {
            start = parseDate(object["start"] as? String)
            end = parseDate(object["end"] as? String)
            label = (object["scope_label"] as? String)?.nilIfEmpty
        }

        let detailLevelRaw = (object["detail_level"] as? String)?.lowercased() ?? ""
        let detailLevel = MemoryQueryDetailLevel(rawValue: detailLevelRaw) ?? .concise

        return MemoryQueryPlan(
            queries: queries.compactMap(\.nilIfEmpty),
            scope: MemoryQueryScope(start: start, end: end, label: label),
            detailLevel: detailLevel
        )
    }

    func parseAnswer(from text: String) -> MemoryQueryAnswerPayload? {
        guard let object = parseJSONObject(from: text) else { return nil }
        let answer = (object["answer"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !answer.isEmpty else {
            return nil
        }

        return MemoryQueryAnswerPayload(
            answer: answer,
            keyPoints: (object["key_points"] as? [String] ?? []).compactMap(\.nilIfEmpty),
            supportingEvents: (object["supporting_events"] as? [String] ?? []).compactMap(\.nilIfEmpty),
            insufficientEvidence: object["insufficient_evidence"] as? Bool ?? false
        )
    }

    func renderJSON(_ result: MemoryQueryResult) -> String {
        let iso = ISO8601DateFormatter()
        var object: [String: Any] = [
            "query": result.query,
            "answer": result.answer,
            "key_points": result.keyPoints,
            "supporting_events": result.supportingEvents,
            "insufficient_evidence": result.insufficientEvidence,
            "sources": [
                "mem0_semantic_count": result.mem0SemanticCount,
                "bm25_store_count": result.bm25StoreCount
            ],
            "generated_at": iso.string(from: result.generatedAt)
        ]

        object["time_scope"] = [
            "start": result.scope.start.map { iso.string(from: $0) } ?? "",
            "end": result.scope.end.map { iso.string(from: $0) } ?? "",
            "label": result.scope.label ?? ""
        ]

        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let rendered = String(data: data, encoding: .utf8) {
            return rendered
        }

        return "{\"error\":\"serialization_failed\"}"
    }

    private func parseJSONObject(from text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = [
            trimmed,
            stripCodeFence(trimmed),
            firstJSONObject(in: trimmed) ?? "",
            firstJSONObject(in: stripCodeFence(trimmed)) ?? ""
        ]

        for candidate in candidates where !candidate.isEmpty {
            guard let data = candidate.data(using: .utf8) else { continue }
            if let raw = try? JSONSerialization.jsonObject(with: data, options: []),
               let object = raw as? [String: Any] {
                return object
            }
        }
        return nil
    }

    private func stripCodeFence(_ text: String) -> String {
        guard text.hasPrefix("```"), text.hasSuffix("```") else {
            return text
        }
        var lines = text.components(separatedBy: .newlines)
        if !lines.isEmpty {
            lines.removeFirst()
        }
        if !lines.isEmpty, lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "```" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func firstJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}")
        else {
            return nil
        }
        guard start <= end else {
            return nil
        }
        return String(text[start...end])
    }

    private func parseDate(_ raw: String?) -> Date? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) {
            return date
        }

        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = .autoupdatingCurrent
        dayFormatter.dateFormat = "yyyy-MM-dd"
        return dayFormatter.date(from: value)
    }
}
