import SwiftUI

struct ActivityLogEvidenceCard: View {
    let item: EvidenceDetailItem

    private let presenter = ActivityLogEvidencePresenter()

    var body: some View {
        let presentation = presenter.present(item: item)

        VStack(alignment: .leading, spacing: 6) {
            Text(presentation.primaryText)
                .font(.system(size: 13))

            if let secondaryText = presentation.secondaryText {
                Text(secondaryText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if !presentation.metadata.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(presentation.metadata) { field in
                        Text("\(field.label): \(field.value)")
                            .font(.system(size: 11, weight: field.emphasis ? .semibold : .regular))
                            .foregroundStyle(field.color)
                    }
                }
            }

            if let transcript = presentation.transcript {
                Text(transcript)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if !presentation.highlights.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(presentation.highlights.prefix(4).enumerated()), id: \.offset) { _, highlight in
                        Text("• \(highlight)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !presentation.entities.isEmpty {
                Text(presentation.entities.joined(separator: ", "))
                    .font(.system(size: 11))
                    .foregroundStyle(.blue)
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct ActivityLogEvidencePresenter: Sendable {
    func present(item: EvidenceDetailItem) -> ActivityLogEvidencePresentation {
        let normalized = normalize(item: item)

        return ActivityLogEvidencePresentation(
            primaryText: primaryText(for: normalized),
            secondaryText: secondaryText(for: normalized),
            metadata: metadata(for: normalized),
            transcript: transcript(for: normalized),
            highlights: highlights(for: normalized),
            entities: normalized.entities
        )
    }

    private func normalize(item: EvidenceDetailItem) -> NormalizedEvidence {
        let embedded = parseEmbeddedAnalysis(from: item)
        let description = resolvedText(
            primary: item.description,
            fallback: [
                embedded?.contentDescription,
                embedded?.description,
                item.contentDescription,
                item.summary
            ]
        )
        let contentDescription = resolvedText(
            primary: item.contentDescription,
            fallback: [
                embedded?.contentDescription,
                embedded?.description,
                item.summary,
                description
            ]
        )
        let layoutDescription = distinct(
            resolvedText(
                primary: item.layoutDescription,
                fallback: [
                    embedded?.layoutDescription,
                    contentDescription
                ]
            ),
            from: contentDescription
        )

        return NormalizedEvidence(
            kind: item.kind,
            description: description,
            contentDescription: contentDescription,
            layoutDescription: layoutDescription,
            problem: resolvedOptional(primary: item.problem, fallback: embedded?.problem),
            success: resolvedOptional(primary: item.success, fallback: embedded?.success),
            userContribution: resolvedOptional(primary: item.userContribution, fallback: embedded?.userContribution),
            suggestionOrDecision: resolvedOptional(primary: item.suggestionOrDecision, fallback: embedded?.suggestionOrDecision),
            status: item.status,
            confidence: item.confidence,
            transcript: resolvedOptional(primary: item.transcript, fallback: embedded?.transcript),
            salientText: mergeUnique(item.salientText, embedded?.salientText ?? []),
            uiElements: item.uiElements.isEmpty ? (embedded?.uiElements ?? []) : item.uiElements,
            entities: mergeUnique(item.entities, embedded?.entities ?? []),
            project: resolvedOptional(primary: item.project, fallback: embedded?.project),
            workspace: resolvedOptional(primary: item.workspace, fallback: embedded?.workspace),
            task: resolvedOptional(primary: item.task, fallback: embedded?.task),
            evidence: mergeUnique(item.evidence, embedded?.evidence ?? [])
        )
    }

    private func primaryText(for evidence: NormalizedEvidence) -> String {
        for candidate in [
            evidence.contentDescription,
            evidence.description,
            evidence.task.map { "Working on \($0)." },
            evidence.project.map { "Activity related to \($0)." },
            "Captured \(evidence.kind.rawValue) activity."
        ] {
            if let candidate, !looksLikeJSONObject(candidate) {
                return candidate
            }
        }
        return "Captured \(evidence.kind.rawValue) activity."
    }

    private func secondaryText(for evidence: NormalizedEvidence) -> String? {
        if let layout = evidence.layoutDescription, !looksLikeJSONObject(layout) {
            return layout
        }
        if evidence.kind == .audio {
            return nil
        }
        return distinct(evidence.description, from: evidence.contentDescription)
    }

    private func transcript(for evidence: NormalizedEvidence) -> String? {
        guard let transcript = evidence.transcript?.nilIfEmpty else {
            return nil
        }
        return compact(transcript, limit: 360)
    }

    private func highlights(for evidence: NormalizedEvidence) -> [String] {
        let salient = evidence.salientText.filter { !$0.isEmpty && !looksLikeJSONObject($0) }
        if !salient.isEmpty {
            return Array(salient.prefix(4))
        }

        let uiHighlights = evidence.uiElements
            .map { element in
                [element.role.nilIfEmpty, element.label.nilIfEmpty, element.value?.nilIfEmpty]
                    .compactMap { $0 }
                    .joined(separator: ": ")
            }
            .compactMap(\.nilIfEmpty)

        if !uiHighlights.isEmpty {
            return Array(uiHighlights.prefix(4))
        }

        return evidence.evidence
            .compactMap { compact($0, limit: 180) }
            .filter { !looksLikeJSONObject($0) }
            .prefix(4)
            .map { $0 }
    }

    private func metadata(for evidence: NormalizedEvidence) -> [ActivityLogEvidenceField] {
        var fields: [ActivityLogEvidenceField] = []

        if let task = evidence.task?.nilIfEmpty {
            fields.append(.init(label: "Working on", value: task, emphasis: true, color: Color.accentColor))
        }
        if let project = evidence.project?.nilIfEmpty {
            fields.append(.init(label: "Project", value: project, emphasis: true))
        }
        if let workspace = evidence.workspace?.nilIfEmpty {
            fields.append(.init(label: "Workspace", value: workspace))
        }
        if let problem = evidence.problem?.nilIfEmpty {
            fields.append(.init(label: "Problem", value: problem, emphasis: true, color: .red))
        }
        if let success = evidence.success?.nilIfEmpty {
            fields.append(.init(label: "Success", value: success, emphasis: true, color: .green))
        }
        if let contribution = evidence.userContribution?.nilIfEmpty {
            fields.append(.init(label: "Contribution", value: contribution))
        }
        if let decision = evidence.suggestionOrDecision?.nilIfEmpty {
            fields.append(.init(label: "Decision", value: decision))
        }
        if evidence.status != .none {
            let confidenceText = String(format: "%.2f", evidence.confidence)
            fields.append(
                .init(
                    label: "Status",
                    value: "\(statusText(evidence.status)) • confidence \(confidenceText)"
                )
            )
        }

        return fields
    }

    private func parseEmbeddedAnalysis(from item: EvidenceDetailItem) -> ArtifactAnalysis? {
        for candidate in [item.description, item.summary] {
            guard let text = candidate.nilIfEmpty, looksLikeJSONObject(text) else {
                continue
            }
            guard let data = text.data(using: .utf8) else {
                continue
            }
            if let analysis = try? JSONDecoder().decode(ArtifactAnalysis.self, from: data) {
                return analysis
            }
        }
        return nil
    }

    private func resolvedText(primary: String?, fallback: [String?]) -> String? {
        let candidates = [primary] + fallback
        for candidate in candidates {
            guard let candidate = candidate?.nilIfEmpty else {
                continue
            }
            if !looksLikeJSONObject(candidate) {
                return candidate
            }
        }
        return candidates.compactMap { $0?.nilIfEmpty }.first
    }

    private func resolvedOptional(primary: String?, fallback: String?) -> String? {
        resolvedText(primary: primary, fallback: [fallback])
    }

    private func distinct(_ candidate: String?, from baseline: String?) -> String? {
        guard let candidate = candidate?.nilIfEmpty else {
            return nil
        }
        guard candidate != baseline?.nilIfEmpty else {
            return nil
        }
        return candidate
    }

    private func mergeUnique(_ lhs: [String], _ rhs: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []

        for value in lhs + rhs {
            guard let normalized = value.nilIfEmpty else {
                continue
            }
            guard seen.insert(normalized).inserted else {
                continue
            }
            output.append(normalized)
        }

        return output
    }

    private func looksLikeJSONObject(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{") && trimmed.hasSuffix("}") && trimmed.contains("\"")
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

    private func statusText(_ status: ArtifactInferenceStatus) -> String {
        switch status {
        case .none:
            return "none"
        case .blocked:
            return "blocked"
        case .inProgress:
            return "in progress"
        case .resolved:
            return "resolved"
        }
    }
}

struct ActivityLogEvidencePresentation {
    let primaryText: String
    let secondaryText: String?
    let metadata: [ActivityLogEvidenceField]
    let transcript: String?
    let highlights: [String]
    let entities: [String]
}

struct ActivityLogEvidenceField: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    let emphasis: Bool
    let color: Color

    init(label: String, value: String, emphasis: Bool = false, color: Color = .secondary) {
        self.label = label
        self.value = value
        self.emphasis = emphasis
        self.color = color
    }
}

private struct NormalizedEvidence {
    let kind: ArtifactKind
    let description: String?
    let contentDescription: String?
    let layoutDescription: String?
    let problem: String?
    let success: String?
    let userContribution: String?
    let suggestionOrDecision: String?
    let status: ArtifactInferenceStatus
    let confidence: Double
    let transcript: String?
    let salientText: [String]
    let uiElements: [ArtifactUIElement]
    let entities: [String]
    let project: String?
    let workspace: String?
    let task: String?
    let evidence: [String]
}
