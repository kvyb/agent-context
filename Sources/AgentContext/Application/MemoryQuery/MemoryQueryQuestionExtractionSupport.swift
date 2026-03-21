import Foundation

struct MemoryQueryQuestionExtractionSupport: Sendable {
    private let scopeParser: MemoryQueryScopeParser

    init(scopeParser: MemoryQueryScopeParser) {
        self.scopeParser = scopeParser
    }

    func requestedDimensions(for question: String) -> [String] {
        let lowered = question.lowercased()
        var output: [String] = []
        var seen = Set<String>()

        func add(_ raw: String?) {
            guard let normalized = normalizeDimension(raw), seen.insert(normalized).inserted else {
                return
            }
            output.append(normalized)
        }

        if lowered.contains("questions answered") || lowered.contains("questions were answered") {
            add("questions answered")
        }

        for cue in MemoryQueryQuestionLexicon.dimensionCuePrefixes {
            guard let range = lowered.range(of: cue) else { continue }
            let tail = String(lowered[range.upperBound...])
            for item in dimensionCandidates(in: tail) {
                add(item)
            }
        }

        return Array(output.prefix(6))
    }

    func focusTerms(for question: String, requestedDimensions: [String]) -> [String] {
        let dimensionTokens = Set(requestedDimensions.flatMap(scopeParser.queryTerms(for:)))

        var seen = Set<String>()
        var output: [String] = []
        for token in scopeParser.queryTerms(for: question) {
            guard token.count >= 3 else { continue }
            guard !dimensionTokens.contains(token) else { continue }
            guard !MemoryQueryQuestionLexicon.genericFocusTerms.contains(token) else { continue }
            guard seen.insert(token).inserted else { continue }
            output.append(token)
            if output.count >= 8 {
                break
            }
        }

        return output
    }

    func personTerms(for question: String) -> [String] {
        let tokens = question
            .split(whereSeparator: { $0.isWhitespace })
            .map { sanitizeNameToken(String($0)) }
            .filter { !$0.isEmpty }

        var output: [String] = []
        var seen = Set<String>()

        for (index, token) in tokens.enumerated() where token.lowercased() == "with" {
            var parts: [String] = []
            var offset = index + 1
            while offset < tokens.count && parts.count < 3 {
                let candidate = tokens[offset].lowercased()
                guard !candidate.isEmpty else {
                    break
                }
                guard !MemoryQueryQuestionLexicon.personStopwords.contains(candidate) else {
                    break
                }
                guard candidate.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else {
                    break
                }

                parts.append(candidate)
                offset += 1
            }

            guard !parts.isEmpty else {
                continue
            }

            let name = parts.joined(separator: " ")
            guard !name.isEmpty, seen.insert(name).inserted else {
                continue
            }
            output.append(name)
        }

        return output
    }

    private func sanitizeNameToken(_ raw: String) -> String {
        let filteredScalars = raw.unicodeScalars.filter { scalar in
            CharacterSet.letters.contains(scalar) || scalar == "'" || scalar == "-"
        }
        return String(String.UnicodeScalarView(filteredScalars))
    }

    private func dimensionCandidates(in tail: String) -> [String] {
        let clause = tail.prefix { !".?!".contains($0) }
        let normalized = clause
            .replacingOccurrences(of: " and ", with: ",")
            .replacingOccurrences(of: " or ", with: ",")
            .replacingOccurrences(of: ";", with: ",")

        return normalized
            .split(separator: ",")
            .map { String($0) }
    }

    private func normalizeDimension(_ raw: String?) -> String? {
        guard var value = raw?
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .lowercased(),
              !value.isEmpty else {
            return nil
        }

        for prefix in MemoryQueryQuestionLexicon.dimensionNormalizationPrefixes where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
        }

        for suffix in MemoryQueryQuestionLexicon.dimensionNormalizationSuffixes where value.hasSuffix(suffix) {
            value.removeLast(suffix.count)
        }

        guard !value.isEmpty else {
            return nil
        }
        guard value.count <= 48 else {
            return nil
        }
        guard !MemoryQueryQuestionLexicon.ignoredDimensions.contains(value) else {
            return nil
        }

        return value.nilIfEmpty
    }
}
