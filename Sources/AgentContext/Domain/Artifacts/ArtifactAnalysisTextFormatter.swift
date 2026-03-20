import Foundation

struct ArtifactAnalysisTextFormatter: Sendable {
    func excerpt(
        kind: ArtifactKind,
        analysis: ArtifactAnalysis?,
        limit: Int = 220
    ) -> String? {
        guard let analysis else {
            return nil
        }

        if kind == .audio, let transcript = analysis.transcript?.nilIfEmpty {
            return compact(transcript, limit: limit)
        }

        return compact(summaryFragments(for: analysis).joined(separator: " | "), limit: limit)
    }

    func summary(for analysis: ArtifactAnalysis?) -> String {
        guard let analysis else {
            return "Retrieved evidence"
        }
        return summaryFragments(for: analysis).joined(separator: " | ").nilIfEmpty ?? "Retrieved evidence"
    }

    func document(
        kind: ArtifactKind,
        metadata: ArtifactMetadata,
        analysis: ArtifactAnalysis?
    ) -> String {
        guard let analysis else {
            return [
                metadata.window.title,
                metadata.window.project,
                metadata.window.workspace,
                metadata.app.appName
            ]
            .compactMap { $0?.nilIfEmpty }
            .joined(separator: " ")
        }

        let fragments = uniqueNormalized(
            [
                analysis.summary,
                kind == .audio ? analysis.transcript : nil,
                analysis.description,
                distinctOptional(analysis.contentDescription, from: analysis.description),
                distinctOptional(analysis.layoutDescription, from: analysis.contentDescription),
                analysis.problem,
                analysis.success,
                analysis.userContribution,
                analysis.suggestionOrDecision,
                analysis.task,
                analysis.project,
                analysis.workspace,
                metadata.window.title,
                metadata.window.project,
                metadata.window.workspace,
                metadata.app.appName,
                analysis.entities.joined(separator: " "),
                analysis.salientText.joined(separator: " "),
                analysis.evidence.joined(separator: " ")
            ]
        )

        return fragments.joined(separator: " ")
    }

    private func summaryFragments(for analysis: ArtifactAnalysis) -> [String] {
        var fragments = uniqueNormalized(
            [
                analysis.summary,
                analysis.description,
                distinctOptional(analysis.contentDescription, from: analysis.description)
            ]
        )

        if let task = analysis.task?.nilIfEmpty {
            fragments.append("Task: \(task)")
        }
        if let decision = analysis.suggestionOrDecision?.nilIfEmpty {
            fragments.append("Decision: \(decision)")
        }
        if let problem = analysis.problem?.nilIfEmpty {
            fragments.append("Problem: \(problem)")
        }
        if let success = analysis.success?.nilIfEmpty {
            fragments.append("Success: \(success)")
        }
        if let salient = Array(analysis.salientText.prefix(4)).nilIfEmptyJoined(separator: "; ") {
            fragments.append("Visible: \(salient)")
        }
        if let layout = distinctOptional(analysis.layoutDescription, from: analysis.contentDescription) {
            fragments.append("Layout: \(layout)")
        }

        return fragments
    }

    private func compact(_ text: String, limit: Int) -> String? {
        guard let normalized = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty else {
            return nil
        }
        guard normalized.count > limit else {
            return normalized
        }
        let index = normalized.index(normalized.startIndex, offsetBy: limit)
        return "\(normalized[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)…"
    }

    private func uniqueNormalized(_ values: [String?]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []

        for value in values {
            guard let normalized = value?
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty else {
                continue
            }
            guard seen.insert(normalized).inserted else { continue }
            output.append(normalized)
        }

        return output
    }

    private func distinctOptional(_ candidate: String?, from baseline: String?) -> String? {
        guard let candidate = candidate?.nilIfEmpty else {
            return nil
        }
        guard candidate != baseline?.nilIfEmpty else {
            return nil
        }
        return candidate
    }
}

private extension Array where Element == String {
    func nilIfEmptyJoined(separator: String) -> String? {
        isEmpty ? nil : joined(separator: separator)
    }
}
