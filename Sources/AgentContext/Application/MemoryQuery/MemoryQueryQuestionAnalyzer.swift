import Foundation

struct MemoryQueryQuestionAnalysis: Sendable {
    let focusTerms: [String]
    let requestedDimensions: [String]
    let seeksEvaluation: Bool
    let seeksWorkSummary: Bool
    let prefersLexicalFirst: Bool
    let prefersDetailedAnswer: Bool
}

struct MemoryQueryQuestionAnalyzer: Sendable {
    private let scopeParser: MemoryQueryScopeParser

    init(scopeParser: MemoryQueryScopeParser) {
        self.scopeParser = scopeParser
    }

    func analyze(question: String) -> MemoryQueryQuestionAnalysis {
        let lowered = question.lowercased()
        let requestedDimensions = requestedDimensions(for: question)
        let focusTerms = focusTerms(for: question, requestedDimensions: requestedDimensions)

        let transcriptLikeTerms = ["transcript", "interview", "meeting", "zoom", "call", "candidate", "notetaker"]
        let prefersLexicalFirst = transcriptLikeTerms.contains { lowered.contains($0) }

        let evaluationTerms = [
            "how well",
            "fit",
            "match",
            "level",
            "assessment",
            "assess",
            "opinion",
            "suggest about",
            "suitability",
            "compare"
        ]
        let seeksEvaluation = evaluationTerms.contains { lowered.contains($0) }

        let workSummaryTerms = [
            "what did user do",
            "what did i do",
            "what happened in",
            "worked on",
            "for work",
            "work on",
            "tasks",
            "projects",
            "blockers",
            "takeaways",
            "struggles"
        ]
        let seeksWorkSummary = workSummaryTerms.contains { lowered.contains($0) }

        let detailedTerms = [
            "timeline",
            "everything",
            "comprehensive",
            "summarize",
            "summary",
            "breakdown",
            "report",
            "details"
        ]
        let prefersDetailedAnswer = scopeParser.hasExplicitDate(in: question)
            || !requestedDimensions.isEmpty
            || detailedTerms.contains { lowered.contains($0) }

        return MemoryQueryQuestionAnalysis(
            focusTerms: focusTerms,
            requestedDimensions: requestedDimensions,
            seeksEvaluation: seeksEvaluation,
            seeksWorkSummary: seeksWorkSummary,
            prefersLexicalFirst: prefersLexicalFirst,
            prefersDetailedAnswer: prefersDetailedAnswer
        )
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

        let cues = [
            "what are the ",
            "what were the ",
            "include ",
            "including ",
            "focus on ",
            "cover ",
            "covering ",
            "summarize ",
            "summarise ",
            "broken down by ",
            "grouped by ",
            "suggest about "
        ]

        for cue in cues {
            guard let range = lowered.range(of: cue) else { continue }
            let tail = String(lowered[range.upperBound...])
            for item in dimensionCandidates(in: tail) {
                add(item)
            }
        }

        return Array(output.prefix(6))
    }

    private func focusTerms(for question: String, requestedDimensions: [String]) -> [String] {
        let dimensionTokens = Set(requestedDimensions.flatMap(scopeParser.queryTerms(for:)))
        let genericTokens: Set<String> = [
            "summary", "summarize", "summarise", "include", "including", "focus", "cover",
            "projects", "project", "tasks", "task", "takeaways", "takeaway", "struggles",
            "struggle", "blockers", "blocker", "questions", "answered", "strengths",
            "weaknesses", "fit", "bugs", "decisions", "issues", "people", "involved",
            "next", "steps", "technical", "topics", "discussed", "open", "follow", "actions",
            "well", "candidate", "engineer", "level", "intermediate", "senior", "junior", "match"
        ]

        var seen = Set<String>()
        var output: [String] = []
        for token in scopeParser.queryTerms(for: question) {
            guard token.count >= 3 else { continue }
            guard !dimensionTokens.contains(token) else { continue }
            guard !genericTokens.contains(token) else { continue }
            guard seen.insert(token).inserted else { continue }
            output.append(token)
            if output.count >= 8 {
                break
            }
        }

        return output
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

        let prefixes = [
            "the ",
            "main ",
            "my ",
            "user ",
            "about ",
            "on ",
            "with ",
            "for "
        ]
        for prefix in prefixes where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
        }

        let suffixes = [
            " from the transcript",
            " in the transcript",
            " in ai core work",
            " in open tulpa work",
            " in opentulpa work",
            " in manychat work"
        ]
        for suffix in suffixes where value.hasSuffix(suffix) {
            value.removeLast(suffix.count)
        }

        guard !value.isEmpty else {
            return nil
        }
        guard value.count <= 48 else {
            return nil
        }

        let ignored = Set([
            "what",
            "that",
            "this",
            "it",
            "call",
            "request",
            "requested",
            "does"
        ])
        guard !ignored.contains(value) else {
            return nil
        }

        return value.nilIfEmpty
    }
}
