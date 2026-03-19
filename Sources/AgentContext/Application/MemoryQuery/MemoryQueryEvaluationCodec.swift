import Foundation

struct MemoryQueryEvaluationCodec: Sendable {
    func parse(from text: String) -> MemoryQueryEvaluation? {
        if let object = parseJSONObject(from: text) {
            return evaluation(from: object)
        }
        return parseLooseEvaluation(from: text)
    }

    private func evaluation(from object: [String: Any]) -> MemoryQueryEvaluation? {
        let summary = (object["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let retrievalExplanation = (object["retrieval_explanation"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let groundednessExplanation = (object["groundedness_explanation"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let answerQualityExplanation = (object["answer_quality_explanation"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !summary.isEmpty, !retrievalExplanation.isEmpty, !groundednessExplanation.isEmpty, !answerQualityExplanation.isEmpty else {
            return nil
        }

        return MemoryQueryEvaluation(
            overallScore: intValue(object["overall_score"], default: 0, min: 0, max: 100),
            queryAlignmentScore: intValue(object["query_alignment_score"], default: 1, min: 1, max: 5),
            retrievalRelevanceScore: intValue(object["retrieval_relevance_score"], default: 1, min: 1, max: 5),
            retrievalCoverageScore: intValue(object["retrieval_coverage_score"], default: 1, min: 1, max: 5),
            groundednessScore: intValue(object["groundedness_score"], default: 1, min: 1, max: 5),
            answerCompletenessScore: intValue(object["answer_completeness_score"], default: 1, min: 1, max: 5),
            summary: summary,
            retrievalExplanation: retrievalExplanation,
            groundednessExplanation: groundednessExplanation,
            answerQualityExplanation: answerQualityExplanation,
            strengths: stringArray(object["strengths"]),
            weaknesses: stringArray(object["weaknesses"]),
            improvementActions: stringArray(object["improvement_actions"]),
            evidenceGaps: stringArray(object["evidence_gaps"])
        )
    }

    private func parseLooseEvaluation(from text: String) -> MemoryQueryEvaluation? {
        let summary = extractJSONStringValue(for: "summary", in: text)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let retrievalExplanation = extractJSONStringValue(for: "retrieval_explanation", in: text)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let groundednessExplanation = extractJSONStringValue(for: "groundedness_explanation", in: text)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let answerQualityExplanation = extractJSONStringValue(for: "answer_quality_explanation", in: text)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !summary.isEmpty, !retrievalExplanation.isEmpty, !groundednessExplanation.isEmpty, !answerQualityExplanation.isEmpty else {
            return nil
        }

        return MemoryQueryEvaluation(
            overallScore: extractInt(for: "overall_score", in: text) ?? 0,
            queryAlignmentScore: clamp(extractInt(for: "query_alignment_score", in: text) ?? 1, min: 1, max: 5),
            retrievalRelevanceScore: clamp(extractInt(for: "retrieval_relevance_score", in: text) ?? 1, min: 1, max: 5),
            retrievalCoverageScore: clamp(extractInt(for: "retrieval_coverage_score", in: text) ?? 1, min: 1, max: 5),
            groundednessScore: clamp(extractInt(for: "groundedness_score", in: text) ?? 1, min: 1, max: 5),
            answerCompletenessScore: clamp(extractInt(for: "answer_completeness_score", in: text) ?? 1, min: 1, max: 5),
            summary: summary,
            retrievalExplanation: retrievalExplanation,
            groundednessExplanation: groundednessExplanation,
            answerQualityExplanation: answerQualityExplanation,
            strengths: extractStringArray(for: "strengths", in: text),
            weaknesses: extractStringArray(for: "weaknesses", in: text),
            improvementActions: extractStringArray(for: "improvement_actions", in: text),
            evidenceGaps: extractStringArray(for: "evidence_gaps", in: text)
        )
    }

    private func stringArray(_ value: Any?) -> [String] {
        (value as? [String] ?? []).compactMap(\.nilIfEmpty)
    }

    private func intValue(_ value: Any?, default defaultValue: Int, min: Int, max: Int) -> Int {
        let raw: Int
        if let intValue = value as? Int {
            raw = intValue
        } else if let doubleValue = value as? Double {
            raw = Int(doubleValue.rounded())
        } else {
            raw = defaultValue
        }
        return Swift.min(max, Swift.max(min, raw))
    }

    private func clamp(_ value: Int, min: Int, max: Int) -> Int {
        Swift.min(max, Swift.max(min, value))
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
            guard let value = extractJSONStringValue(startingAt: quoteStart, in: text, endIndex: &cursor) else {
                break
            }
            if let normalized = value.nilIfEmpty {
                values.append(normalized)
            }
            if cursor < text.endIndex, text[cursor] == "]" {
                break
            }
        }

        return values
    }

    private func extractInt(for key: String, in text: String) -> Int? {
        guard let keyRange = text.range(of: "\"\(key)\"") else {
            return nil
        }
        guard let colonIndex = text[keyRange.upperBound...].firstIndex(of: ":") else {
            return nil
        }

        var cursor = text.index(after: colonIndex)
        while cursor < text.endIndex, text[cursor].isWhitespace {
            cursor = text.index(after: cursor)
        }

        var end = cursor
        while end < text.endIndex, text[end].isNumber {
            end = text.index(after: end)
        }
        guard end > cursor else {
            return nil
        }
        return Int(text[cursor..<end])
    }

    private func extractJSONStringValue(startingAt openingQuote: String.Index, in text: String, endIndex: inout String.Index) -> String? {
        var index = text.index(after: openingQuote)
        var isEscaped = false
        while index < text.endIndex {
            let character = text[index]
            if character == "\"" && !isEscaped {
                let raw = String(text[text.index(after: openingQuote)..<index])
                endIndex = text.index(after: index)
                return decodeJSONStringLiteral(raw)
            }
            if character == "\\" && !isEscaped {
                isEscaped = true
            } else {
                isEscaped = false
            }
            index = text.index(after: index)
        }

        endIndex = text.endIndex
        let raw = String(text[text.index(after: openingQuote)...])
        return decodeJSONStringLiteral(raw)
    }

    private func decodeJSONStringLiteral(_ raw: String) -> String? {
        let wrapped = "\"\(raw)\""
        guard let data = wrapped.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(String.self, from: data) else {
            return raw
        }
        return decoded
    }
}
