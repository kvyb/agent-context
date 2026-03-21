import Foundation

func decodeArtifactAnalysis(
    from text: String,
    fallbackProject: String? = nil,
    fallbackWorkspace: String? = nil,
    fallbackTaskHint: String? = nil
) -> ArtifactAnalysis {
    if let object = parseArtifactJSON(text) {
        let transcript = objectString(object, keys: ["transcript"])
        var description = normalizeArtifactField(
            objectString(object, keys: ["description", "summary"])
        ) ?? "insufficient evidence"
        let contentDescription = normalizeArtifactField(
            objectString(object, keys: ["content_description", "contentDescription"])
        )
        let layoutDescription = normalizeArtifactField(
            objectString(object, keys: ["layout_description", "layoutDescription"])
        )
        description = sanitizeSummaryPhrasing(description)
        let salientText = uniqueStrings(
            (object["salient_text"] as? [String]) ?? (object["salientText"] as? [String]) ?? []
        )
        let uiElements = decodeArtifactUIElements(object["ui_elements"] ?? object["uiElements"])

        var project = normalizeArtifactField(objectString(object, keys: ["project"])) ?? fallbackProject?.nilIfEmpty
        var workspace = normalizeArtifactField(objectString(object, keys: ["workspace"])) ?? fallbackWorkspace?.nilIfEmpty
        var task = normalizeTask(objectString(object, keys: ["task"]))
        let evidence = uniqueStrings(object["evidence"] as? [String] ?? [])
        var entities = uniqueStrings(object["entities"] as? [String] ?? [])
        var problem = normalizeArtifactField(objectString(object, keys: ["problem"]))
        var success = normalizeArtifactField(objectString(object, keys: ["success"]))
        let userContribution = normalizeArtifactField(objectString(object, keys: ["user_contribution", "userContribution"]))
        let suggestionOrDecision = normalizeArtifactField(
            objectString(object, keys: ["suggestion_or_decision", "suggestionOrDecision"])
        )
        let confidence = object["confidence"] == nil ? 0 : clampConfidence(object["confidence"])
        let insufficient = boolValue(object["insufficient_evidence"])
            ?? boolValue(object["insufficientEvidence"])
            ?? description.lowercased().contains("insufficient evidence")

        if confidence < highConfidenceInferenceThreshold {
            problem = nil
            success = nil
        }

        if insufficient {
            return ArtifactAnalysis(
                description: "insufficient evidence",
                contentDescription: "insufficient evidence",
                layoutDescription: "insufficient evidence",
                problem: nil,
                success: nil,
                userContribution: nil,
                suggestionOrDecision: nil,
                status: .none,
                confidence: 0,
                summary: "insufficient evidence",
                transcript: transcript,
                salientText: [],
                uiElements: [],
                entities: entities,
                insufficientEvidence: true,
                project: project,
                workspace: workspace,
                task: task,
                evidence: []
            )
        }

        let inferenceSeed = composeArtifactSummary(
            description: description,
            problem: problem,
            success: success,
            userContribution: userContribution,
            suggestionOrDecision: suggestionOrDecision,
            status: .none,
            insufficient: false
        )

        task = normalizeTask(task)
            ?? inferTask(summary: inferenceSeed, evidence: evidence, fallbackHint: fallbackTaskHint)

        if project == nil {
            project = inferProject(from: inferenceSeed, entities: entities)
        }
        if workspace == nil {
            workspace = inferWorkspace(from: inferenceSeed, entities: entities)
        }

        if let project, !entities.contains(project) {
            entities.append(project)
        }
        if let workspace, !entities.contains(workspace) {
            entities.append(workspace)
        }
        if let task, !entities.contains(task) {
            entities.append(task)
        }

        if description == "{" || description.count < 24 {
            description = fallbackSummary(project: project, workspace: workspace, task: task, evidence: evidence) ?? description
        }

        var status = parseArtifactInferenceStatus(object["status"])
        if status == .none {
            if problem != nil {
                status = .blocked
            } else if success != nil {
                status = .resolved
            } else if userContribution != nil || suggestionOrDecision != nil || task != nil {
                status = .inProgress
            }
        }

        var summary = composeArtifactSummary(
            description: description,
            problem: problem,
            success: success,
            userContribution: userContribution,
            suggestionOrDecision: suggestionOrDecision,
            status: status,
            insufficient: false
        )
        if let task, !summaryContainsTask(summary, task: task) {
            summary = "Working on \(task). \(summary)"
        }

        return ArtifactAnalysis(
            description: description,
            contentDescription: contentDescription ?? description,
            layoutDescription: layoutDescription ?? contentDescription ?? description,
            problem: problem,
            success: success,
            userContribution: userContribution,
            suggestionOrDecision: suggestionOrDecision,
            status: status,
            confidence: confidence,
            summary: summary,
            transcript: transcript,
            salientText: salientText,
            uiElements: uiElements,
            entities: entities,
            insufficientEvidence: false,
            project: project,
            workspace: workspace,
            task: task,
            evidence: evidence
        )
    }

    if let repaired = ArtifactAnalysisRecovery.recoverRawJSONObjectLikeText(
        text,
        fallbackProject: fallbackProject,
        fallbackWorkspace: fallbackWorkspace,
        fallbackTask: fallbackTaskHint
    ) {
        return repaired
    }

    let fallback = cleanedFreeformText(text) ?? "insufficient evidence"
    let insufficient = fallback.lowercased().contains("insufficient evidence")
    let description = insufficient ? "insufficient evidence" : sanitizeSummaryPhrasing(fallback)
    let summary = composeArtifactSummary(
        description: description,
        problem: nil,
        success: nil,
        userContribution: nil,
        suggestionOrDecision: nil,
        status: .none,
        insufficient: insufficient
    )
    return ArtifactAnalysis(
        description: description,
        contentDescription: description,
        layoutDescription: description,
        problem: nil,
        success: nil,
        userContribution: nil,
        suggestionOrDecision: nil,
        status: .none,
        confidence: 0,
        summary: summary,
        transcript: nil,
        salientText: [],
        uiElements: [],
        entities: [],
        insufficientEvidence: insufficient,
        project: nil,
        workspace: nil,
        task: nil,
        evidence: []
    )
}

func decodeStructuredSynthesis(
    from text: String,
    defaultTask: String? = nil,
    defaultProject: String? = nil,
    defaultWorkspace: String? = nil,
    defaultAppName: String? = nil,
    defaultBundleID: String? = nil
) -> StructuredSynthesis {
    guard let object = parseArtifactJSON(text) else {
        let fallbackSummary = cleanedFreeformText(text) ?? "insufficient evidence"
        let insufficient = fallbackSummary.lowercased().contains("insufficient evidence")
        let fallbackSegment = fallbackTaskSegment(
            summary: fallbackSummary,
            defaultTask: defaultTask,
            defaultProject: defaultProject,
            defaultWorkspace: defaultWorkspace,
            defaultAppName: defaultAppName,
            defaultBundleID: defaultBundleID
        )
        return StructuredSynthesis(
            summary: fallbackSummary,
            entities: fallbackSegment.map { [$0.task] } ?? [],
            insufficientEvidence: insufficient,
            taskSegments: fallbackSegment.map { [$0] } ?? []
        )
    }

    let summary = (object["summary"] as? String)?.nilIfEmpty ?? "insufficient evidence"
    let insufficient = (object["insufficient_evidence"] as? Bool) ?? summary.lowercased().contains("insufficient evidence")
    var entities = uniqueStrings(object["entities"] as? [String] ?? [])

    var segments: [TaskSegmentDraft] = []
    if let rawSegments = object["task_segments"] as? [[String: Any]] {
        for raw in rawSegments {
            let task = normalizeTask((raw["task"] as? String)?.nilIfEmpty)
                ?? normalizeTask(defaultTask)
                ?? inferTask(summary: summary, evidence: raw["evidence_refs"] as? [String] ?? [], fallbackHint: nil)
                ?? "unknown task"

            let issueOrGoal = normalizeTask((raw["issue_or_goal"] as? String)?.nilIfEmpty)
            let actions = uniqueStrings(raw["actions"] as? [String] ?? [])
            let outcome = normalizeTask((raw["outcome"] as? String)?.nilIfEmpty)
            let nextStep = normalizeTask((raw["next_step"] as? String)?.nilIfEmpty)
            let people = uniqueStrings(raw["people"] as? [String] ?? [])
            let blocker = normalizeArtifactField((raw["blocker"] as? String)?.nilIfEmpty)
            let status = parseTaskSegmentStatus((raw["status"] as? String), outcome: outcome, nextStep: nextStep)
            let confidence = clampConfidence(raw["confidence"])
            let evidenceRefs = uniqueStrings(raw["evidence_refs"] as? [String] ?? [])
            let evidenceExcerpts = uniqueStrings(raw["evidence_excerpts"] as? [String] ?? [])
            var segmentEntities = uniqueStrings(raw["entities"] as? [String] ?? [])
            let project = normalizeTask((raw["project"] as? String)?.nilIfEmpty) ?? normalizeTask(defaultProject)
            let workspace = normalizeTask((raw["workspace"] as? String)?.nilIfEmpty) ?? normalizeTask(defaultWorkspace)
            let repo = normalizeTask((raw["repo"] as? String)?.nilIfEmpty)
            let document = normalizeTask((raw["document"] as? String)?.nilIfEmpty)
            let url = normalizeTask((raw["url"] as? String)?.nilIfEmpty)
            let appName = normalizeTask((raw["app_name"] as? String)?.nilIfEmpty) ?? normalizeTask(defaultAppName)
            let bundleID = normalizeTask((raw["bundle_id"] as? String)?.nilIfEmpty) ?? normalizeTask(defaultBundleID)
            let artifactKinds = uniqueArtifactKinds(raw["artifact_kinds"] as? [String] ?? [])
            let sourceKinds = uniquePromotedSourceKinds(raw["source_kinds"] as? [String] ?? [])

            for marker in [task, issueOrGoal, project, workspace, repo, document, blocker] {
                if let marker, !segmentEntities.contains(marker) {
                    segmentEntities.append(marker)
                }
            }
            for person in people where !segmentEntities.contains(person) {
                segmentEntities.append(person)
            }

            segments.append(
                TaskSegmentDraft(
                    task: task,
                    issueOrGoal: issueOrGoal,
                    actions: actions,
                    outcome: outcome,
                    nextStep: nextStep,
                    people: people,
                    blocker: blocker,
                    status: status,
                    confidence: confidence,
                    evidenceRefs: evidenceRefs,
                    evidenceExcerpts: evidenceExcerpts,
                    entities: segmentEntities,
                    project: project,
                    workspace: workspace,
                    repo: repo,
                    document: document,
                    url: url,
                    appName: appName,
                    bundleID: bundleID,
                    artifactKinds: artifactKinds,
                    sourceKinds: sourceKinds
                )
            )
        }
    }

    if segments.isEmpty, !insufficient,
       let fallback = fallbackTaskSegment(
           summary: summary,
           defaultTask: defaultTask,
           defaultProject: defaultProject,
           defaultWorkspace: defaultWorkspace,
           defaultAppName: defaultAppName,
           defaultBundleID: defaultBundleID
       ) {
        segments = [fallback]
    }

    for segment in segments {
        if !entities.contains(segment.task) {
            entities.append(segment.task)
        }
        if let project = segment.project, !entities.contains(project) {
            entities.append(project)
        }
        if let workspace = segment.workspace, !entities.contains(workspace) {
            entities.append(workspace)
        }
    }

    return StructuredSynthesis(
        summary: summary,
        entities: entities,
        insufficientEvidence: insufficient,
        taskSegments: segments
    )
}

private let highConfidenceInferenceThreshold = 0.72

private func decodeArtifactUIElements(_ raw: Any?) -> [ArtifactUIElement] {
    guard let items = raw as? [[String: Any]] else {
        return []
    }

    return items.compactMap { item in
        let role = normalizeArtifactField(item["role"] as? String) ?? ""
        let label = normalizeArtifactField(item["label"] as? String) ?? ""
        let value = normalizeArtifactField(item["value"] as? String)
        let region = normalizeArtifactField(item["region"] as? String)
        guard role.nilIfEmpty != nil || label.nilIfEmpty != nil else {
            return nil
        }
        return ArtifactUIElement(role: role, label: label, value: value, region: region)
    }
}

private func uniqueArtifactKinds(_ raw: [String]) -> [ArtifactKind] {
    var seen = Set<String>()
    var output: [ArtifactKind] = []
    for value in raw {
        guard let kind = ArtifactKind(rawValue: value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            continue
        }
        guard seen.insert(kind.rawValue).inserted else { continue }
        output.append(kind)
    }
    return output
}

private func uniquePromotedSourceKinds(_ raw: [String]) -> [PromotedSourceKind] {
    var seen = Set<String>()
    var output: [PromotedSourceKind] = []
    for value in raw {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let kind = PromotedSourceKind(rawValue: normalized), seen.insert(kind.rawValue).inserted else {
            continue
        }
        output.append(kind)
    }
    return output
}

private func objectString(_ object: [String: Any], keys: [String]) -> String? {
    for key in keys {
        if let text = (object[key] as? String)?.nilIfEmpty {
            return text
        }
    }
    return nil
}

private func boolValue(_ raw: Any?) -> Bool? {
    if let value = raw as? Bool {
        return value
    }
    if let value = raw as? NSNumber {
        return value.boolValue
    }
    if let value = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        switch value {
        case "true", "1", "yes":
            return true
        case "false", "0", "no":
            return false
        default:
            return nil
        }
    }
    return nil
}

private func normalizeArtifactField(_ text: String?) -> String? {
    guard var value = text?.nilIfEmpty else { return nil }
    value = value
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    while value.contains("  ") {
        value = value.replacingOccurrences(of: "  ", with: " ")
    }
    if value == "{" || value == "}" {
        return nil
    }
    return value.nilIfEmpty
}

private func parseArtifactInferenceStatus(_ raw: Any?) -> ArtifactInferenceStatus {
    guard let value = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
        return .none
    }

    switch value {
    case "blocked", "stalled":
        return .blocked
    case "in_progress", "in progress", "active", "working", "ongoing":
        return .inProgress
    case "resolved", "done", "complete", "completed", "success":
        return .resolved
    default:
        return .none
    }
}

private func composeArtifactSummary(
    description: String,
    problem: String?,
    success: String?,
    userContribution: String?,
    suggestionOrDecision: String?,
    status: ArtifactInferenceStatus,
    insufficient: Bool
) -> String {
    if insufficient {
        return "insufficient evidence"
    }

    var parts: [String] = [ensureSentence(sanitizeSummaryPhrasing(description))]

    if let problem {
        parts.append("Problem: \(ensureSentence(problem))")
    }
    if let success {
        parts.append("Success: \(ensureSentence(success))")
    }
    if let userContribution {
        parts.append("User contribution: \(ensureSentence(userContribution))")
    }
    if let suggestionOrDecision {
        parts.append("Suggestion/decision: \(ensureSentence(suggestionOrDecision))")
    }
    if status != .none {
        parts.append("Status: \(artifactStatusLabel(status)).")
    }

    return parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
}

private func artifactStatusLabel(_ status: ArtifactInferenceStatus) -> String {
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

private func ensureSentence(_ text: String) -> String {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let last = value.last else { return value }
    if [".", "!", "?"].contains(last) {
        return value
    }
    return "\(value)."
}

private func parseArtifactJSON(_ text: String) -> [String: Any]? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

    let candidates: [String] = [
        trimmed,
        stripMarkdownCodeFence(trimmed),
        firstJSONObjectString(in: trimmed) ?? "",
        firstJSONObjectString(in: stripMarkdownCodeFence(trimmed)) ?? ""
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

private func stripMarkdownCodeFence(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("```") else {
        return trimmed
    }

    var lines = trimmed.components(separatedBy: .newlines)
    if !lines.isEmpty {
        lines.removeFirst()
    }

    while let last = lines.last, last.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") {
        lines.removeLast()
    }

    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

private func firstJSONObjectString(in text: String) -> String? {
    var startIndex: String.Index?
    var depth = 0
    var inString = false
    var escaping = false

    for index in text.indices {
        let character = text[index]

        if escaping {
            escaping = false
            continue
        }

        if inString {
            if character == "\\" {
                escaping = true
            } else if character == "\"" {
                inString = false
            }
            continue
        }

        if character == "\"" {
            inString = true
            continue
        }

        if character == "{" {
            if startIndex == nil {
                startIndex = index
            }
            depth += 1
            continue
        }

        if character == "}" && depth > 0 {
            depth -= 1
            if depth == 0, let startIndex {
                let end = text.index(after: index)
                return String(text[startIndex..<end])
            }
        }
    }

    return nil
}

private func fallbackSummary(
    project: String?,
    workspace: String?,
    task: String?,
    evidence: [String]
) -> String? {
    var fragments: [String] = []
    if let task {
        fragments.append(task)
    }
    if let project {
        fragments.append("project \(project)")
    }
    if let workspace {
        fragments.append("workspace \(workspace)")
    }
    if !evidence.isEmpty {
        fragments.append(evidence.prefix(2).joined(separator: "; "))
    }
    return fragments.joined(separator: " • ").nilIfEmpty
}

private func fallbackTaskSegment(
    summary: String,
    defaultTask: String?,
    defaultProject: String?,
    defaultWorkspace: String?,
    defaultAppName: String?,
    defaultBundleID: String?
) -> TaskSegmentDraft? {
    let task = normalizeTask(defaultTask)
        ?? inferTask(summary: summary, evidence: [], fallbackHint: nil)
        ?? normalizeTask(extractQuotedPhrase(from: summary))
    guard let task else { return nil }

    let status: TaskSegmentStatus = summary.lowercased().contains("insufficient evidence") ? .unknown : .inProgress
    return TaskSegmentDraft(
        task: task,
        issueOrGoal: nil,
        actions: [],
        outcome: nil,
        nextStep: nil,
        people: [],
        blocker: nil,
        status: status,
        confidence: 0.45,
        evidenceRefs: [],
        evidenceExcerpts: [],
        entities: [task],
        project: normalizeTask(defaultProject),
        workspace: normalizeTask(defaultWorkspace),
        repo: nil,
        document: nil,
        url: nil,
        appName: normalizeTask(defaultAppName),
        bundleID: normalizeTask(defaultBundleID),
        artifactKinds: [],
        sourceKinds: []
    )
}

private func parseTaskSegmentStatus(_ raw: String?, outcome: String?, nextStep: String?) -> TaskSegmentStatus {
    let normalized = raw?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

    switch normalized {
    case "done", "completed", "complete", "resolved":
        return .done
    case "in_progress", "in progress", "active", "working":
        return .inProgress
    case "pending", "todo", "to_do":
        return .pending
    case "blocked", "stalled":
        return .blocked
    default:
        break
    }

    if outcome?.nilIfEmpty != nil {
        return .done
    }
    if nextStep?.nilIfEmpty != nil {
        return .pending
    }
    return .inProgress
}

private func clampConfidence(_ raw: Any?) -> Double {
    if let value = raw as? Double {
        return max(0, min(1, value))
    }
    if let value = raw as? NSNumber {
        return max(0, min(1, value.doubleValue))
    }
    if let text = raw as? String, let value = Double(text) {
        return max(0, min(1, value))
    }
    return 0.55
}

private func normalizeTask(_ task: String?) -> String? {
    guard var value = task?.nilIfEmpty else { return nil }
    value = value
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))

    if value.count < 4 {
        return nil
    }

    let lowercased = value.lowercased()
    let generic = [
        "working in app",
        "using app",
        "general browsing",
        "unknown",
        "n/a"
    ]
    if generic.contains(where: { lowercased == $0 }) {
        return nil
    }

    return value
}

private func inferTask(summary: String, evidence: [String], fallbackHint: String?) -> String? {
    let candidates: [String?] = [
        extractQuotedPhrase(from: summary),
        extractWorkingOnPhrase(from: summary),
        fallbackHint,
        evidence.first
    ]

    for candidate in candidates {
        if let normalized = normalizeTask(candidate) {
            return normalized
        }
    }
    return nil
}

private func sanitizeSummaryPhrasing(_ summary: String) -> String {
    var output = summary.trimmingCharacters(in: .whitespacesAndNewlines)
    let replacements: [(String, String)] = [
        ("The user is ", ""),
        ("The user ", ""),
        ("User is ", "")
    ]

    for (prefix, replacement) in replacements {
        if output.hasPrefix(prefix) {
            output = replacement + output.dropFirst(prefix.count)
            break
        }
    }

    if let first = output.first {
        output = String(first).uppercased() + output.dropFirst()
    }
    return output
}

private func inferProject(from summary: String, entities: [String]) -> String? {
    for entity in entities {
        let lowercased = entity.lowercased()
        if lowercased.contains("project") || lowercased.contains("workspace") {
            return entity
        }
    }

    let lower = summary.lowercased()
    if let range = lower.range(of: "project ") {
        let tail = String(lower[range.upperBound...])
        let value = tail.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true).first
        return normalizeTask(value.map(String.init))
    }
    return nil
}

private func inferWorkspace(from summary: String, entities: [String]) -> String? {
    for entity in entities {
        let lowercased = entity.lowercased()
        if lowercased.contains("workspace") || lowercased.contains("thread") {
            return entity
        }
    }

    let lower = summary.lowercased()
    if let range = lower.range(of: "workspace ") {
        let tail = String(lower[range.upperBound...])
        let value = tail.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true).first
        return normalizeTask(value.map(String.init))
    }
    return nil
}

private func extractQuotedPhrase(from text: String) -> String? {
    let components = text.components(separatedBy: "'")
    if components.count >= 3 {
        return components[1].nilIfEmpty
    }
    return nil
}

private func extractWorkingOnPhrase(from text: String) -> String? {
    let lower = text.lowercased()
    guard let range = lower.range(of: "working on ") else { return nil }
    let rawTail = String(text[range.upperBound...])
    let delimiterSet = CharacterSet(charactersIn: ".,;\n")
    if let delimiterRange = rawTail.rangeOfCharacter(from: delimiterSet) {
        return String(rawTail[..<delimiterRange.lowerBound]).nilIfEmpty
    }
    return rawTail.nilIfEmpty
}

private func summaryContainsTask(_ summary: String, task: String) -> Bool {
    let summaryLower = summary.lowercased()
    let taskLower = task.lowercased()
    return summaryLower.contains(taskLower)
}

private func cleanedFreeformText(_ text: String) -> String? {
    let cleaned = stripMarkdownCodeFence(text)
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let value = cleaned.nilIfEmpty else {
        return nil
    }
    if value == "{" || value == "}" {
        return "insufficient evidence"
    }
    return value
}

private func uniqueStrings(_ values: [String]) -> [String] {
    var seen = Set<String>()
    var output: [String] = []
    for value in values {
        guard let normalized = value.nilIfEmpty else { continue }
        if seen.insert(normalized).inserted {
            output.append(normalized)
        }
    }
    return output
}
