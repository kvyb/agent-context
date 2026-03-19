import Foundation

struct MemoryQueryJSONCodec: Sendable {
    func parsePlan(from text: String) -> MemoryQueryPlan? {
        guard let object = parseJSONObject(from: text) else { return nil }

        let structuredSteps = parseSteps(from: object)
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

        let scope = MemoryQueryScope(start: start, end: end, label: label)
        if !structuredSteps.isEmpty {
            return MemoryQueryPlan(
                steps: structuredSteps,
                scope: scope,
                detailLevel: detailLevel
            )
        }

        return MemoryQueryPlan(
            queries: queries.compactMap(\.nilIfEmpty),
            scope: scope,
            detailLevel: detailLevel
        )
    }

    func parseAnswer(from text: String) -> MemoryQueryAnswerPayload? {
        if let object = parseJSONObject(from: text) {
            return answerPayload(from: object)
        }
        return parseLooseAnswer(from: text)
    }

    private func answerPayload(from object: [String: Any]) -> MemoryQueryAnswerPayload? {
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

    private func parseLooseAnswer(from text: String) -> MemoryQueryAnswerPayload? {
        guard let answer = extractJSONStringValue(for: "answer", in: text)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !answer.isEmpty else {
            return nil
        }

        return MemoryQueryAnswerPayload(
            answer: answer,
            keyPoints: extractStringArray(for: "key_points", in: text),
            supportingEvents: extractStringArray(for: "supporting_events", in: text),
            insufficientEvidence: extractBoolean(for: "insufficient_evidence", in: text) ?? false
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

    private func parseSteps(from object: [String: Any]) -> [MemoryQueryPlanStep] {
        guard let rawSteps = object["steps"] as? [[String: Any]] else {
            return []
        }

        return rawSteps.compactMap { raw in
            guard let query = (raw["query"] as? String)?.nilIfEmpty else {
                return nil
            }

            let phaseRaw = (raw["phase"] as? String)?.lowercased() ?? MemoryQueryStepPhase.evidence.rawValue
            let phase = MemoryQueryStepPhase(rawValue: phaseRaw) ?? .evidence

            let sources: Set<MemoryEvidenceSource>
            if let rawSources = raw["sources"] as? [String] {
                let parsed = rawSources.reduce(into: Set<MemoryEvidenceSource>()) { acc, source in
                    if let value = MemoryEvidenceSource(cliValue: source) {
                        acc.insert(value)
                    }
                }
                sources = parsed.isEmpty ? Set(MemoryEvidenceSource.allCases) : parsed
            } else {
                sources = Set(MemoryEvidenceSource.allCases)
            }

            let maxResults: Int?
            if let rawMax = raw["max_results"] as? Int {
                maxResults = max(1, min(rawMax, 50))
            } else if let rawMax = raw["max_results"] as? Double {
                maxResults = max(1, min(Int(rawMax), 50))
            } else {
                maxResults = nil
            }

            return MemoryQueryPlanStep(
                query: query,
                sources: sources,
                phase: phase,
                maxResults: maxResults
            )
        }
    }

    private func extractJSONStringValue(for key: String, in text: String) -> String? {
        guard let keyRange = text.range(of: "\"\(key)\"") else {
            return nil
        }
        guard let colonIndex = text[keyRange.upperBound...].firstIndex(of: ":") else {
            return nil
        }
        guard let openingQuote = text[text.index(after: colonIndex)...].firstIndex(of: "\"") else {
            return nil
        }

        var index = text.index(after: openingQuote)
        var isEscaped = false
        while index < text.endIndex {
            let character = text[index]
            if character == "\"" && !isEscaped {
                let raw = String(text[text.index(after: openingQuote)..<index])
                return decodeJSONStringLiteral(raw)
            }
            if character == "\\" && !isEscaped {
                isEscaped = true
            } else {
                isEscaped = false
            }
            index = text.index(after: index)
        }

        let raw = String(text[text.index(after: openingQuote)...])
        return decodeJSONStringLiteral(raw)
    }

    private func extractStringArray(for key: String, in text: String) -> [String] {
        guard let keyRange = text.range(of: "\"\(key)\"") else {
            return []
        }
        guard let colonIndex = text[keyRange.upperBound...].firstIndex(of: ":") else {
            return []
        }
        guard let openingBracket = text[text.index(after: colonIndex)...].firstIndex(of: "[") else {
            return []
        }

        var values: [String] = []
        var cursor = text.index(after: openingBracket)
        while cursor < text.endIndex {
            guard let quoteStart = text[cursor...].firstIndex(of: "\"") else {
                break
            }
            var index = text.index(after: quoteStart)
            var isEscaped = false
            var closed = false
            while index < text.endIndex {
                let character = text[index]
                if character == "\"" && !isEscaped {
                    let raw = String(text[text.index(after: quoteStart)..<index])
                    values.append(decodeJSONStringLiteral(raw))
                    cursor = text.index(after: index)
                    closed = true
                    break
                }
                if character == "\\" && !isEscaped {
                    isEscaped = true
                } else {
                    isEscaped = false
                }
                index = text.index(after: index)
            }
            if !closed {
                let raw = String(text[text.index(after: quoteStart)...])
                values.append(decodeJSONStringLiteral(raw))
                break
            }
            if let closingBracket = text[cursor...].firstIndex(of: "]"),
               closingBracket < (text[cursor...].firstIndex(of: "\"") ?? text.endIndex) {
                break
            }
        }
        return values.compactMap(\.nilIfEmpty)
    }

    private func extractBoolean(for key: String, in text: String) -> Bool? {
        guard let keyRange = text.range(of: "\"\(key)\"") else {
            return nil
        }
        let tail = text[keyRange.upperBound...]
        guard let trueRange = tail.range(of: "true") else {
            if tail.range(of: "false") != nil {
                return false
            }
            return nil
        }
        if let falseRange = tail.range(of: "false"), falseRange.lowerBound < trueRange.lowerBound {
            return false
        }
        return true
    }

    private func decodeJSONStringLiteral(_ raw: String) -> String {
        let wrapped = "\"\(raw)\""
        if let data = wrapped.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data, options: []) as? String {
            return decoded
        }

        return raw
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
