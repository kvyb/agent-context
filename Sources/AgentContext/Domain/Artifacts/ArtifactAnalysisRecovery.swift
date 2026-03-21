import Foundation

enum ArtifactAnalysisRecovery {
    static func recoverEmbeddedAnalysis(
        from candidates: [String?],
        fallbackProject: String? = nil,
        fallbackWorkspace: String? = nil,
        fallbackTask: String? = nil
    ) -> ArtifactAnalysis? {
        for candidate in candidates {
            guard let candidate = candidate?.nilIfEmpty else {
                continue
            }
            guard let recovered = recoverRawJSONObjectLikeText(
                candidate,
                fallbackProject: fallbackProject,
                fallbackWorkspace: fallbackWorkspace,
                fallbackTask: fallbackTask
            ) else {
                continue
            }
            return recovered
        }
        return nil
    }

    static func recoverRawJSONObjectLikeText(
        _ text: String,
        fallbackProject: String? = nil,
        fallbackWorkspace: String? = nil,
        fallbackTask: String? = nil
    ) -> ArtifactAnalysis? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.contains("\"") else {
            return nil
        }

        if let object = parseJSONObject(trimmed) {
            return buildAnalysis(
                from: object,
                fallbackProject: fallbackProject,
                fallbackWorkspace: fallbackWorkspace,
                fallbackTask: fallbackTask
            )
        }

        return buildAnalysis(
            fromRawText: trimmed,
            fallbackProject: fallbackProject,
            fallbackWorkspace: fallbackWorkspace,
            fallbackTask: fallbackTask
        )
    }

    private static func buildAnalysis(
        from object: [String: Any],
        fallbackProject: String?,
        fallbackWorkspace: String?,
        fallbackTask: String?
    ) -> ArtifactAnalysis? {
        let description = normalizedString(in: object, keys: ["description", "summary"])
        let contentDescription = normalizedString(in: object, keys: ["content_description", "contentDescription"])
        let layoutDescription = normalizedString(in: object, keys: ["layout_description", "layoutDescription"])
        let summary = normalizedString(in: object, keys: ["summary"])
        let task = normalizedString(in: object, keys: ["task"]) ?? fallbackTask?.nilIfEmpty
        let project = normalizedString(in: object, keys: ["project"]) ?? fallbackProject?.nilIfEmpty
        let workspace = normalizedString(in: object, keys: ["workspace"]) ?? fallbackWorkspace?.nilIfEmpty
        let problem = normalizedString(in: object, keys: ["problem"])
        let success = normalizedString(in: object, keys: ["success"])
        let userContribution = normalizedString(in: object, keys: ["user_contribution", "userContribution"])
        let suggestionOrDecision = normalizedString(in: object, keys: ["suggestion_or_decision", "suggestionOrDecision"])
        let transcript = normalizedString(in: object, keys: ["transcript"])
        let evidence = uniqueStrings(in: object, keys: ["evidence"])
        let salientText = uniqueStrings(in: object, keys: ["salient_text", "salientText"])
        let entities = uniqueStrings(in: object, keys: ["entities"])
        let uiElements = uiElements(in: object)
        let status = parseStatus(raw: normalizedString(in: object, keys: ["status"]))
        let confidence = clampConfidence(object["confidence"])
        let insufficientEvidence = parseBool(object["insufficient_evidence"] ?? object["insufficientEvidence"]) ?? false

        let primaryDescription = description ?? contentDescription ?? summary ?? task
        guard let primaryDescription else {
            return nil
        }

        return ArtifactAnalysis(
            description: primaryDescription,
            contentDescription: contentDescription ?? primaryDescription,
            layoutDescription: layoutDescription ?? contentDescription ?? primaryDescription,
            problem: problem,
            success: success,
            userContribution: userContribution,
            suggestionOrDecision: suggestionOrDecision,
            status: status,
            confidence: confidence,
            summary: summary ?? primaryDescription,
            transcript: transcript,
            salientText: salientText,
            uiElements: uiElements,
            entities: mergeUnique(entities, extras: [project, workspace, task]),
            insufficientEvidence: insufficientEvidence,
            project: project,
            workspace: workspace,
            task: task,
            evidence: evidence
        )
    }

    private static func buildAnalysis(
        fromRawText text: String,
        fallbackProject: String?,
        fallbackWorkspace: String?,
        fallbackTask: String?
    ) -> ArtifactAnalysis? {
        let description = extractJSONString(keys: ["description", "summary"], from: text)
        let contentDescription = extractJSONString(keys: ["content_description", "contentDescription"], from: text)
        let layoutDescription = extractJSONString(keys: ["layout_description", "layoutDescription"], from: text)
        let summary = extractJSONString(keys: ["summary"], from: text)
        let task = extractJSONString(keys: ["task"], from: text) ?? fallbackTask?.nilIfEmpty
        let project = extractJSONString(keys: ["project"], from: text) ?? fallbackProject?.nilIfEmpty
        let workspace = extractJSONString(keys: ["workspace"], from: text) ?? fallbackWorkspace?.nilIfEmpty
        let problem = extractJSONString(keys: ["problem"], from: text)
        let success = extractJSONString(keys: ["success"], from: text)
        let userContribution = extractJSONString(keys: ["user_contribution", "userContribution"], from: text)
        let suggestionOrDecision = extractJSONString(keys: ["suggestion_or_decision", "suggestionOrDecision"], from: text)
        let transcript = extractJSONString(keys: ["transcript"], from: text)
        let evidence = extractStringArray(key: "evidence", from: text)
        let salientText = extractStringArray(key: "salient_text", from: text, fallbackKey: "salientText")
        let entities = extractStringArray(key: "entities", from: text)
        let status = parseStatus(raw: extractJSONString(keys: ["status"], from: text))
        let confidence = clampConfidence(extractDouble(keys: ["confidence"], from: text))
        let insufficientEvidence = extractBool(keys: ["insufficient_evidence", "insufficientEvidence"], from: text) ?? false

        let primaryDescription = description ?? contentDescription ?? summary ?? task
        guard let primaryDescription else {
            return nil
        }

        return ArtifactAnalysis(
            description: primaryDescription,
            contentDescription: contentDescription ?? primaryDescription,
            layoutDescription: layoutDescription ?? contentDescription ?? primaryDescription,
            problem: problem,
            success: success,
            userContribution: userContribution,
            suggestionOrDecision: suggestionOrDecision,
            status: status,
            confidence: confidence,
            summary: summary ?? primaryDescription,
            transcript: transcript,
            salientText: salientText,
            uiElements: [],
            entities: mergeUnique(entities, extras: [project, workspace, task]),
            insufficientEvidence: insufficientEvidence,
            project: project,
            workspace: workspace,
            task: task,
            evidence: evidence
        )
    }

    private static func parseJSONObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func normalizedString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = object[key] else {
                continue
            }
            if value is NSNull {
                return nil
            }
            if let string = value as? String {
                let normalized = string
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return normalized.nilIfEmpty
            }
        }
        return nil
    }

    private static func uniqueStrings(in object: [String: Any], keys: [String]) -> [String] {
        for key in keys {
            guard let array = object[key] as? [Any] else {
                continue
            }
            return uniqueStrings(from: array)
        }
        return []
    }

    private static func uiElements(in object: [String: Any]) -> [ArtifactUIElement] {
        let keys = ["ui_elements", "uiElements"]
        for key in keys {
            guard let array = object[key] as? [[String: Any]] else {
                continue
            }

            return array.compactMap { element in
                let role = normalizedString(in: element, keys: ["role"]) ?? ""
                let label = normalizedString(in: element, keys: ["label"]) ?? ""
                let value = normalizedString(in: element, keys: ["value"])
                let region = normalizedString(in: element, keys: ["region"])
                guard role.nilIfEmpty != nil || label.nilIfEmpty != nil else {
                    return nil
                }
                return ArtifactUIElement(role: role, label: label, value: value, region: region)
            }
        }
        return []
    }

    private static func uniqueStrings(from raw: [Any]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []

        for value in raw {
            guard let string = (value as? String)?
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty else {
                continue
            }
            guard seen.insert(string).inserted else {
                continue
            }
            output.append(string)
        }

        return output
    }

    private static func mergeUnique(_ values: [String], extras: [String?]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []

        for candidate in values + extras.compactMap({ $0?.nilIfEmpty }) {
            guard seen.insert(candidate).inserted else {
                continue
            }
            output.append(candidate)
        }

        return output
    }

    private static func parseStatus(raw: String?) -> ArtifactInferenceStatus {
        switch raw?.lowercased() {
        case "blocked", "stalled":
            return .blocked
        case "in_progress", "in progress", "working", "active", "ongoing":
            return .inProgress
        case "resolved", "done", "complete", "completed", "success":
            return .resolved
        default:
            return .none
        }
    }

    private static func clampConfidence(_ raw: Any?) -> Double {
        let value: Double
        if let raw = raw as? Double {
            value = raw
        } else if let raw = raw as? NSNumber {
            value = raw.doubleValue
        } else if let raw = raw as? String, let parsed = Double(raw) {
            value = parsed
        } else {
            value = 0
        }
        return max(0, min(1, value))
    }

    private static func parseBool(_ raw: Any?) -> Bool? {
        if let raw = raw as? Bool {
            return raw
        }
        if let raw = raw as? NSNumber {
            return raw.boolValue
        }
        if let raw = raw as? String {
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
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

    private static func extractJSONString(keys: [String], from text: String) -> String? {
        for key in keys {
            if let value = extractJSONString(key: key, from: text) {
                return value
            }
        }
        return nil
    }

    private static func extractJSONString(key: String, from text: String) -> String? {
        let pattern = #""\#(key)"\s*:\s*"((?:\\.|[^"\\])*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }

        let escaped = String(text[captureRange])
        let literal = "\"\(escaped)\""
        guard let data = literal.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(String.self, from: data) else {
            return escaped.nilIfEmpty
        }
        return decoded.nilIfEmpty
    }

    private static func extractStringArray(key: String, from text: String, fallbackKey: String? = nil) -> [String] {
        for candidateKey in [key, fallbackKey].compactMap({ $0 }) {
            let pattern = #""\#(candidateKey)"\s*:\s*\["#
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  let arrayStart = Range(match.range, in: text)?.upperBound else {
                continue
            }

            let remainder = text[arrayStart...]
            let body: Substring
            if let closingBracket = remainder.firstIndex(of: "]") {
                body = remainder[..<closingBracket]
            } else {
                body = remainder
            }

            let stringPattern = #""((?:\\.|[^"\\])*)""#
            guard let stringRegex = try? NSRegularExpression(pattern: stringPattern) else {
                continue
            }
            let bodyString = String(body)
            let bodyRange = NSRange(bodyString.startIndex..<bodyString.endIndex, in: bodyString)
            let values = stringRegex.matches(in: bodyString, range: bodyRange).compactMap { match -> String? in
                guard let range = Range(match.range(at: 1), in: bodyString) else {
                    return nil
                }
                let escaped = String(bodyString[range])
                let literal = "\"\(escaped)\""
                guard let data = literal.data(using: .utf8),
                      let decoded = try? JSONDecoder().decode(String.self, from: data) else {
                    return escaped.nilIfEmpty
                }
                return decoded.nilIfEmpty
            }

            if !values.isEmpty {
                return Array(NSOrderedSet(array: values)) as? [String] ?? values
            }
        }

        return []
    }

    private static func extractDouble(keys: [String], from text: String) -> Double? {
        for key in keys {
            let pattern = #""\#(key)"\s*:\s*(-?\d+(?:\.\d+)?)"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  let captureRange = Range(match.range(at: 1), in: text),
                  let value = Double(text[captureRange]) else {
                continue
            }
            return value
        }
        return nil
    }

    private static func extractBool(keys: [String], from text: String) -> Bool? {
        for key in keys {
            let pattern = #""\#(key)"\s*:\s*(true|false)"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  let captureRange = Range(match.range(at: 1), in: text) else {
                continue
            }
            return text[captureRange].lowercased() == "true"
        }
        return nil
    }
}
