import Foundation

struct TranscriptUnitPromoter: Sendable {
    func promote(metadata: ArtifactMetadata, analysis: ArtifactAnalysis) -> [TranscriptUnitRecord] {
        guard metadata.kind == .audio else {
            return []
        }
        guard let transcript = analysis.transcript?.nilIfEmpty else {
            return []
        }

        let sessionID = metadata.intervalID?.nilIfEmpty
            ?? "audio-\(metadata.app.appName)-\(Int(metadata.capturedAt.timeIntervalSince1970 / 600))"
        let topicTags = uniqueList(parsedTopics(from: analysis.summary) + analysis.entities + [analysis.task, analysis.project, analysis.workspace].compactMap { $0 })
        let people = inferredPeople(from: analysis.entities)
        let excerpts = transcriptWindows(from: transcript)
        guard !excerpts.isEmpty else {
            return []
        }

        return excerpts.enumerated().map { index, window in
            let speakerLabel = firstSpeakerLabel(in: window)
            let kind: TranscriptUnitKind = speakerLabelCount(in: window) >= 2 ? .speakerExchange : .transcriptExcerpt
            let excerpt = compactText(window, limit: 420)
            let summary = summarize(window: excerpt, fallback: analysis.summary, task: analysis.task, topicTags: topicTags)
            return TranscriptUnitRecord(
                id: "\(metadata.id)-transcript-\(index)",
                evidenceID: metadata.id,
                occurredAt: metadata.capturedAt,
                appName: metadata.app.appName,
                bundleID: metadata.app.bundleID,
                project: analysis.project?.nilIfEmpty ?? metadata.window.project?.nilIfEmpty,
                workspace: analysis.workspace?.nilIfEmpty ?? metadata.window.workspace?.nilIfEmpty,
                task: analysis.task?.nilIfEmpty,
                sessionID: sessionID,
                kind: kind,
                speakerLabel: speakerLabel,
                summary: summary,
                excerptText: excerpt,
                topicTags: topicTags,
                people: people,
                entities: uniqueList(analysis.entities + [analysis.project, analysis.workspace, analysis.task].compactMap { $0 }),
                sourceEvidenceRefs: [metadata.id],
                sourceExcerpts: [excerpt]
            )
        }
    }

    private func parsedTopics(from summary: String) -> [String] {
        let lines = summary
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var topics: [String] = []
        var inTopics = false
        for line in lines {
            let lowered = line.lowercased()
            if lowered.hasPrefix("topics:") {
                inTopics = true
                let tail = line.dropFirst("Topics:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                if !tail.isEmpty {
                    topics.append(contentsOf: splitTopicLine(tail))
                }
                continue
            }
            if inTopics {
                if lowered.hasPrefix("decisions:") || lowered.hasPrefix("action items:") || lowered.hasPrefix("open questions") {
                    break
                }
                topics.append(contentsOf: splitTopicLine(line))
            }
        }
        return uniqueList(topics)
    }

    private func splitTopicLine(_ line: String) -> [String] {
        line
            .replacingOccurrences(of: ";", with: ",")
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) }
            .filter { !$0.isEmpty }
    }

    private func inferredPeople(from entities: [String]) -> [String] {
        uniqueList(
            entities.filter { entity in
                let trimmed = entity.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count >= 3, trimmed.count <= 64 else { return false }
                let words = trimmed.split(separator: " ")
                guard (1...3).contains(words.count) else { return false }
                return words.allSatisfy { word in
                    guard let first = word.first else { return false }
                    return first.isUppercase
                }
            }
        )
    }

    private func transcriptWindows(from transcript: String) -> [String] {
        let speakerWindows = speakerTurnWindows(from: transcript)
        if !speakerWindows.isEmpty {
            return speakerWindows
        }

        let collapsed = transcript
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else {
            return []
        }

        var windows: [String] = []
        var current = ""
        for sentence in collapsed.split(separator: ".") {
            let normalized = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            let candidate = current.isEmpty ? "\(normalized)." : "\(current) \(normalized)."
            if candidate.count > 420, !current.isEmpty {
                windows.append(current)
                current = "\(normalized)."
            } else {
                current = candidate
            }
        }
        if !current.isEmpty {
            windows.append(current)
        }
        return windows
    }

    private func speakerTurnWindows(from transcript: String) -> [String] {
        let turns = speakerTurns(from: transcript)
        guard !turns.isEmpty else {
            return []
        }

        var output: [String] = []
        var index = 0
        while index < turns.count {
            let endIndex = min(index + 2, turns.count)
            let window = turns[index..<endIndex].joined(separator: " ")
            output.append(window)
            index = endIndex
        }
        return output
    }

    private func speakerTurns(from transcript: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "(S\\d+:.*?)(?=\\sS\\d+:|$)", options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let nsrange = NSRange(transcript.startIndex..<transcript.endIndex, in: transcript)
        let matches = regex.matches(in: transcript, options: [], range: nsrange)
        return matches.compactMap { match in
            guard let range = Range(match.range(at: 1), in: transcript) else {
                return nil
            }
            return transcript[range].trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func firstSpeakerLabel(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "S\\d+:", options: []) else {
            return nil
        }
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsrange),
              let range = Range(match.range, in: text) else {
            return nil
        }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private func speakerLabelCount(in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: "S\\d+:", options: []) else {
            return 0
        }
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: nsrange).count
    }

    private func summarize(window: String, fallback: String, task: String?, topicTags: [String]) -> String {
        if let task = task?.nilIfEmpty {
            let topicText = topicTags.prefix(3).joined(separator: ", ")
            if !topicText.isEmpty {
                return "\(task): \(topicText)"
            }
            return task
        }
        return compactText(fallback.isEmpty ? window : fallback, limit: 180)
    }

    private func compactText(_ text: String, limit: Int) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else {
            return collapsed
        }
        let index = collapsed.index(collapsed.startIndex, offsetBy: limit)
        return "\(collapsed[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)…"
    }

    private func uniqueList(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for raw in values {
            guard let normalized = raw.nilIfEmpty else { continue }
            if seen.insert(normalized).inserted {
                output.append(normalized)
            }
        }
        return output
    }
}
