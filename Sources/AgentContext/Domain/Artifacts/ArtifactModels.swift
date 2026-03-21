import Foundation

struct ArtifactUIElement: Codable, Sendable, Hashable {
    let role: String
    let label: String
    let value: String?
    let region: String?
}

struct ArtifactAnalysis: Codable, Sendable {
    let description: String
    let contentDescription: String
    let layoutDescription: String
    let problem: String?
    let success: String?
    let userContribution: String?
    let suggestionOrDecision: String?
    let status: ArtifactInferenceStatus
    let confidence: Double
    let summary: String
    let transcript: String?
    let salientText: [String]
    let uiElements: [ArtifactUIElement]
    let entities: [String]
    let insufficientEvidence: Bool
    let project: String?
    let workspace: String?
    let task: String?
    let evidence: [String]

    enum CodingKeys: String, CodingKey {
        case description
        case contentDescription
        case contentDescriptionSnake = "content_description"
        case layoutDescription
        case layoutDescriptionSnake = "layout_description"
        case problem
        case success
        case userContribution
        case userContributionSnake = "user_contribution"
        case suggestionOrDecision
        case suggestionOrDecisionSnake = "suggestion_or_decision"
        case status
        case confidence
        case summary
        case transcript
        case salientText
        case salientTextSnake = "salient_text"
        case uiElements
        case uiElementsSnake = "ui_elements"
        case entities
        case insufficientEvidence
        case insufficientEvidenceSnake = "insufficient_evidence"
        case project
        case workspace
        case task
        case evidence
    }

    init(
        description: String,
        contentDescription: String? = nil,
        layoutDescription: String? = nil,
        problem: String? = nil,
        success: String? = nil,
        userContribution: String? = nil,
        suggestionOrDecision: String? = nil,
        status: ArtifactInferenceStatus = .none,
        confidence: Double = 0,
        summary: String,
        transcript: String?,
        salientText: [String] = [],
        uiElements: [ArtifactUIElement] = [],
        entities: [String],
        insufficientEvidence: Bool,
        project: String? = nil,
        workspace: String? = nil,
        task: String? = nil,
        evidence: [String] = []
    ) {
        self.description = description
        self.contentDescription = contentDescription?.nilIfEmpty ?? description
        self.layoutDescription = layoutDescription?.nilIfEmpty ?? self.contentDescription
        self.problem = problem
        self.success = success
        self.userContribution = userContribution
        self.suggestionOrDecision = suggestionOrDecision
        self.status = status
        self.confidence = max(0, min(1, confidence))
        self.summary = summary
        self.transcript = transcript
        self.salientText = salientText.compactMap(\.nilIfEmpty)
        self.uiElements = uiElements.filter { !$0.role.isEmpty || !$0.label.isEmpty }
        self.entities = entities
        self.insufficientEvidence = insufficientEvidence
        self.project = project
        self.workspace = workspace
        self.task = task
        self.evidence = evidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSummary = try container.decodeIfPresent(String.self, forKey: .summary)
        let decodedDescription = try container.decodeIfPresent(String.self, forKey: .description)
        let decodedContentDescriptionValue = try container.decodeIfPresent(String.self, forKey: .contentDescription)?.nilIfEmpty
        let decodedContentDescriptionSnake = try container.decodeIfPresent(String.self, forKey: .contentDescriptionSnake)?.nilIfEmpty
        let decodedLayoutDescriptionValue = try container.decodeIfPresent(String.self, forKey: .layoutDescription)?.nilIfEmpty
        let decodedLayoutDescriptionSnake = try container.decodeIfPresent(String.self, forKey: .layoutDescriptionSnake)?.nilIfEmpty

        if let repaired = ArtifactAnalysisRecovery.recoverEmbeddedAnalysis(
            from: [
                decodedContentDescriptionValue,
                decodedContentDescriptionSnake,
                decodedDescription,
                decodedSummary,
                decodedLayoutDescriptionValue,
                decodedLayoutDescriptionSnake
            ]
        ) {
            self = repaired
            return
        }

        description = decodedDescription?.nilIfEmpty ?? decodedSummary?.nilIfEmpty ?? "insufficient evidence"
        let decodedContentDescription = decodedContentDescriptionValue ?? decodedContentDescriptionSnake
        contentDescription = decodedContentDescription ?? description
        layoutDescription = decodedLayoutDescriptionValue ?? decodedLayoutDescriptionSnake ?? contentDescription
        summary = decodedSummary?.nilIfEmpty ?? description
        problem = try container.decodeIfPresent(String.self, forKey: .problem)?.nilIfEmpty
        success = try container.decodeIfPresent(String.self, forKey: .success)?.nilIfEmpty
        let decodedUserContribution = try container.decodeIfPresent(String.self, forKey: .userContribution)?.nilIfEmpty
        let decodedUserContributionSnake = try container.decodeIfPresent(String.self, forKey: .userContributionSnake)?.nilIfEmpty
        userContribution = decodedUserContribution ?? decodedUserContributionSnake

        let decodedSuggestionOrDecision = try container.decodeIfPresent(String.self, forKey: .suggestionOrDecision)?.nilIfEmpty
        let decodedSuggestionOrDecisionSnake = try container.decodeIfPresent(String.self, forKey: .suggestionOrDecisionSnake)?.nilIfEmpty
        suggestionOrDecision = decodedSuggestionOrDecision ?? decodedSuggestionOrDecisionSnake

        if let statusRaw = try container.decodeIfPresent(String.self, forKey: .status)?.nilIfEmpty {
            let normalizedStatus = statusRaw.lowercased()
            switch normalizedStatus {
            case "in_progress", "in progress", "active", "working":
                status = .inProgress
            case "blocked", "stalled":
                status = .blocked
            case "resolved", "done", "completed":
                status = .resolved
            default:
                status = ArtifactInferenceStatus(rawValue: normalizedStatus) ?? .none
            }
        } else {
            status = .none
        }
        confidence = max(0, min(1, try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0))
        transcript = try container.decodeIfPresent(String.self, forKey: .transcript)
        let decodedSalientTextValue = try container.decodeIfPresent([String].self, forKey: .salientText)
        let decodedSalientTextSnake = try container.decodeIfPresent([String].self, forKey: .salientTextSnake)
        let decodedSalientText = decodedSalientTextValue ?? decodedSalientTextSnake ?? []
        salientText = decodedSalientText.compactMap(\.nilIfEmpty)
        let decodedUIElementsValue = try container.decodeIfPresent([ArtifactUIElement].self, forKey: .uiElements)
        let decodedUIElementsSnake = try container.decodeIfPresent([ArtifactUIElement].self, forKey: .uiElementsSnake)
        uiElements = (decodedUIElementsValue ?? decodedUIElementsSnake ?? []).filter { !$0.role.isEmpty || !$0.label.isEmpty }
        entities = try container.decodeIfPresent([String].self, forKey: .entities) ?? []
        let decodedInsufficientEvidence = try container.decodeIfPresent(Bool.self, forKey: .insufficientEvidence)
        let decodedInsufficientEvidenceSnake = try container.decodeIfPresent(Bool.self, forKey: .insufficientEvidenceSnake)
        insufficientEvidence = decodedInsufficientEvidence ?? decodedInsufficientEvidenceSnake ?? false
        project = try container.decodeIfPresent(String.self, forKey: .project)
        workspace = try container.decodeIfPresent(String.self, forKey: .workspace)
        task = try container.decodeIfPresent(String.self, forKey: .task)
        evidence = try container.decodeIfPresent([String].self, forKey: .evidence) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(description, forKey: .description)
        try container.encode(contentDescription, forKey: .contentDescription)
        try container.encode(layoutDescription, forKey: .layoutDescription)
        try container.encodeIfPresent(problem, forKey: .problem)
        try container.encodeIfPresent(success, forKey: .success)
        try container.encodeIfPresent(userContribution, forKey: .userContribution)
        try container.encodeIfPresent(suggestionOrDecision, forKey: .suggestionOrDecision)
        try container.encode(status, forKey: .status)
        try container.encode(max(0, min(1, confidence)), forKey: .confidence)
        try container.encode(summary, forKey: .summary)
        try container.encodeIfPresent(transcript, forKey: .transcript)
        try container.encode(salientText, forKey: .salientText)
        try container.encode(uiElements, forKey: .uiElements)
        try container.encode(entities, forKey: .entities)
        try container.encode(insufficientEvidence, forKey: .insufficientEvidence)
        try container.encodeIfPresent(project, forKey: .project)
        try container.encodeIfPresent(workspace, forKey: .workspace)
        try container.encodeIfPresent(task, forKey: .task)
        try container.encode(evidence, forKey: .evidence)
    }
}

struct ArtifactPerceptionRecord: Codable, Sendable, Identifiable {
    let id: String
    let evidenceID: String
    let occurredAt: Date
    let kind: ArtifactKind
    let appName: String
    let bundleID: String?
    let windowTitle: String?
    let documentPath: String?
    let windowURL: String?
    let workspace: String?
    let project: String?
    let intervalID: String?
    let captureReason: String
    let sequenceInInterval: Int
    let analysis: ArtifactAnalysis
}

enum ArtifactInferenceStatus: String, Codable, Sendable, CaseIterable {
    case none
    case blocked
    case inProgress = "in_progress"
    case resolved
}
