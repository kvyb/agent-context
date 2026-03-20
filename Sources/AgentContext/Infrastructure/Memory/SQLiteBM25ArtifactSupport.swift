import Foundation

struct SQLiteBM25ArtifactSupport: Sendable {
    private let textFormatter: ArtifactAnalysisTextFormatter

    init(textFormatter: ArtifactAnalysisTextFormatter = ArtifactAnalysisTextFormatter()) {
        self.textFormatter = textFormatter
    }

    func transcriptChunks(
        for row: StoredEvidenceRecord,
        analysis: MemoryQueryQuestionAnalysis
    ) -> [ArtifactCandidate] {
        guard hasTranscript(row) else {
            return []
        }

        let document = evidenceDocument(for: row)
        guard shouldInclude(row: row, analysis: analysis, document: document) else {
            return []
        }

        let transcript = row.analysis?.transcript?.nilIfEmpty ?? ""
        let segments = chunkTranscript(transcript)
        let summary = row.analysis.flatMap { $0.summary.nilIfEmpty }
            ?? row.analysis.flatMap { $0.description.nilIfEmpty }
            ?? "Retrieved transcript evidence"
        let project = row.analysis?.project?.nilIfEmpty ?? row.metadata.window.project?.nilIfEmpty
        let task = row.analysis?.task?.nilIfEmpty
        let workspace = row.analysis?.workspace?.nilIfEmpty ?? row.metadata.window.workspace?.nilIfEmpty
        let title = row.metadata.window.title?.nilIfEmpty

        return segments.enumerated().map { index, segment in
            let normalizedSegment = segment
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let speakerLabels = Set(matches(pattern: "S\\d+:", in: normalizedSegment).map { $0.lowercased() })
            let hasSpeakerWindow = !speakerLabels.isEmpty
            let isExchange = speakerLabels.count >= 2

            var metadata: [String: String] = [
                "scope": "evidence",
                "artifact_kind": row.metadata.kind.rawValue,
                "capture_reason": row.metadata.captureReason,
                "window_title": title ?? "",
                "workspace": workspace ?? "",
                "task": task ?? "",
                "has_transcript": "true",
                "retrieval_unit": LexicalRetrievalUnit.transcriptChunk.rawValue,
                "transcript_chunk_index": String(index)
            ]
            if let project {
                metadata["project"] = project
            }
            if let entities = row.analysis?.entities.nonEmptyJoined(separator: "|") {
                metadata["entities"] = entities
            }
            if hasSpeakerWindow {
                metadata["speaker_turn_window"] = "true"
            }
            if isExchange {
                metadata["speaker_exchange"] = "true"
            }

            var contextualParts: [String] = []
            let transcriptLabel = isExchange ? "Transcript exchange" : "Transcript excerpt"
            contextualParts.append("\(transcriptLabel): \(normalizedSegment)")
            if let task {
                contextualParts.append("Task: \(task)")
            }
            if let project {
                contextualParts.append("Project: \(project)")
            }
            if let workspace {
                contextualParts.append("Workspace: \(workspace)")
            }
            if let title {
                contextualParts.append("Window title: \(title)")
            }
            contextualParts.append("Summary: \(summary)")
            if let extraEvidence = row.analysis?.evidence.nonEmptyJoined(separator: " ") {
                contextualParts.append(extraEvidence)
            }

            let contextualText = contextualParts.joined(separator: " | ")
            return ArtifactCandidate(
                id: "evidence|\(row.metadata.id)|chunk|\(index)",
                appName: row.metadata.app.appName.nilIfEmpty,
                project: project,
                occurredAt: row.metadata.capturedAt,
                document: contextualText,
                summary: contextualText,
                metadata: metadata,
                baseScore: 0.18
            )
        }
    }

    func artifactCandidate(
        for row: StoredEvidenceRecord,
        analysis: MemoryQueryQuestionAnalysis
    ) -> ArtifactCandidate? {
        guard let rowAnalysis = row.analysis else {
            return nil
        }
        if analysis.prefersLexicalFirst, hasTranscript(row) {
            return nil
        }

        let document = evidenceDocument(for: row)
        guard !document.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let summary = artifactSummary(for: row)
        let project = rowAnalysis.project?.nilIfEmpty ?? row.metadata.window.project?.nilIfEmpty
        let workspace = rowAnalysis.workspace?.nilIfEmpty ?? row.metadata.window.workspace?.nilIfEmpty
        let task = rowAnalysis.task?.nilIfEmpty
        let title = row.metadata.window.title?.nilIfEmpty

        var metadata: [String: String] = [
            "scope": "evidence",
            "artifact_kind": row.metadata.kind.rawValue,
            "capture_reason": row.metadata.captureReason,
            "window_title": title ?? "",
            "workspace": workspace ?? "",
            "task": task ?? "",
            "retrieval_unit": LexicalRetrievalUnit.artifactEvidence.rawValue
        ]
        if let project {
            metadata["project"] = project
        }
        if let entities = rowAnalysis.entities.nonEmptyJoined(separator: "|") {
            metadata["entities"] = entities
        }
        if rowAnalysis.status != .none {
            metadata["artifact_status"] = rowAnalysis.status.rawValue
        }

        var baseScore = row.metadata.kind == .screenshot ? 0.18 : 0.12
        if rowAnalysis.status == .blocked {
            baseScore += 0.08
        }
        if isMetaNoise(document) {
            baseScore -= 0.2
        }

        return ArtifactCandidate(
            id: "evidence|\(row.metadata.id)",
            appName: row.metadata.app.appName.nilIfEmpty,
            project: project,
            occurredAt: row.metadata.capturedAt,
            document: document,
            summary: summary,
            metadata: metadata,
            baseScore: baseScore
        )
    }

    func transcriptUnitCandidate(for unit: TranscriptUnitRecord) -> ArtifactCandidate {
        let isExchange = unit.kind == .speakerExchange
        var metadata: [String: String] = [
            "scope": "transcript_unit",
            "artifact_kind": ArtifactKind.audio.rawValue,
            "has_transcript": "true",
            "task": unit.task ?? "",
            "workspace": unit.workspace ?? "",
            "retrieval_unit": LexicalRetrievalUnit.transcriptUnit.rawValue,
            "transcript_unit_kind": unit.kind.rawValue
        ]
        if let project = unit.project?.nilIfEmpty {
            metadata["project"] = project
        }
        if let appName = unit.appName?.nilIfEmpty {
            metadata["app_name"] = appName
        }
        if let sessionID = unit.sessionID?.nilIfEmpty {
            metadata["session_id"] = sessionID
        }
        if let speakerLabel = unit.speakerLabel?.nilIfEmpty {
            metadata["speaker_label"] = speakerLabel
        }
        if !unit.topicTags.isEmpty {
            metadata["topic_tags"] = unit.topicTags.joined(separator: "|")
        }
        if !unit.people.isEmpty {
            metadata["people"] = unit.people.joined(separator: "|")
        }
        if !unit.entities.isEmpty {
            metadata["entities"] = unit.entities.joined(separator: "|")
        }
        if isExchange {
            metadata["speaker_exchange"] = "true"
            metadata["speaker_turn_window"] = "true"
        }

        var contextualParts: [String] = []
        contextualParts.append(isExchange ? "Transcript exchange: \(unit.excerptText)" : "Transcript excerpt: \(unit.excerptText)")
        contextualParts.append("Summary: \(unit.summary)")
        if let task = unit.task?.nilIfEmpty {
            contextualParts.append("Task: \(task)")
        }
        if let project = unit.project?.nilIfEmpty {
            contextualParts.append("Project: \(project)")
        }
        if let workspace = unit.workspace?.nilIfEmpty {
            contextualParts.append("Workspace: \(workspace)")
        }
        if !unit.topicTags.isEmpty {
            contextualParts.append("Topics: \(unit.topicTags.prefix(6).joined(separator: ", "))")
        }
        if !unit.people.isEmpty {
            contextualParts.append("People: \(unit.people.joined(separator: ", "))")
        }

        return ArtifactCandidate(
            id: "transcript-unit|\(unit.id)",
            appName: unit.appName?.nilIfEmpty,
            project: unit.project?.nilIfEmpty,
            occurredAt: unit.occurredAt,
            document: contextualParts.joined(separator: " | "),
            summary: contextualParts.prefix(4).joined(separator: " | "),
            metadata: metadata,
            baseScore: isExchange ? 0.88 : 0.72
        )
    }

    func hasTranscript(_ row: StoredEvidenceRecord) -> Bool {
        row.analysis?.transcript?.nilIfEmpty != nil
    }

    func containsInterviewMarker(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return SQLiteBM25Heuristics.interviewMarkers.contains { lowered.contains($0) }
    }

    private func shouldInclude(
        row: StoredEvidenceRecord,
        analysis: MemoryQueryQuestionAnalysis,
        document: String
    ) -> Bool {
        if row.metadata.kind == .audio {
            return hasTranscript(row)
        }
        if analysis.prefersLexicalFirst {
            return containsInterviewMarker(document)
        }
        return true
    }

    private func evidenceDocument(for row: StoredEvidenceRecord) -> String {
        textFormatter.document(
            kind: row.metadata.kind,
            metadata: row.metadata,
            analysis: row.analysis
        )
    }

    private func artifactSummary(for row: StoredEvidenceRecord) -> String {
        textFormatter.summary(for: row.analysis)
    }

    private func isMetaNoise(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return SQLiteBM25Heuristics.metaNoiseIndicators.contains { lowered.contains($0) }
    }

    private func chunkTranscript(_ transcript: String) -> [String] {
        let collapsed = transcript
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n+", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else {
            return []
        }

        let speakerWindows = speakerTurnWindows(from: collapsed)
        if !speakerWindows.isEmpty {
            return speakerWindows
        }

        let pieces = collapsed
            .components(separatedBy: .newlines)
            .flatMap { $0.components(separatedBy: "|") }
            .flatMap { piece in
                piece.split(whereSeparator: { ".!?".contains($0) }).map(String.init)
            }
            .map {
                $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            }
            .filter { !$0.isEmpty }

        guard !pieces.isEmpty else {
            return [collapsed]
        }

        var chunks: [String] = []
        var current = ""
        for piece in pieces {
            let candidate = current.isEmpty ? piece : "\(current). \(piece)"
            if candidate.count <= 280 {
                current = candidate
                continue
            }

            if !current.isEmpty {
                chunks.append(current)
            }
            current = piece
        }

        if !current.isEmpty {
            chunks.append(current)
        }

        return chunks.isEmpty ? [collapsed] : chunks
    }

    private func speakerTurnWindows(from transcript: String) -> [String] {
        let turns = speakerTurns(from: transcript)
        guard !turns.isEmpty else {
            return []
        }
        guard turns.count > 1 else {
            return turns
        }

        var windows: [String] = []
        var seen = Set<String>()

        func appendWindow(_ value: String) {
            let normalized = value
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return }
            guard normalized.count <= 520 else { return }
            guard seen.insert(normalized).inserted else { return }
            windows.append(normalized)
        }

        for index in turns.indices {
            if index + 1 < turns.count {
                appendWindow("\(turns[index]) \(turns[index + 1])")
            }
            if index + 2 < turns.count {
                appendWindow("\(turns[index]) \(turns[index + 1]) \(turns[index + 2])")
            }
        }

        return windows.isEmpty ? turns : windows
    }

    private func speakerTurns(from transcript: String) -> [String] {
        let pattern = "(S\\d+:.*?)(?=(?:\\s*S\\d+:)|$)"
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return []
        }

        let nsrange = NSRange(transcript.startIndex..<transcript.endIndex, in: transcript)
        let matches = regex.matches(in: transcript, options: [], range: nsrange)
        return matches.compactMap { match in
            guard let range = Range(match.range(at: 1), in: transcript) else {
                return nil
            }
            return transcript[range]
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters.subtracting(CharacterSet(charactersIn: ":"))))
        }
    }

    private func matches(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: nsrange).compactMap { match in
            guard let range = Range(match.range, in: text) else {
                return nil
            }
            return String(text[range])
        }
    }
}

private extension Collection where Element == String {
    func nonEmptyJoined(separator: String) -> String? {
        let values = compactMap(\.nilIfEmpty)
        guard !values.isEmpty else { return nil }
        return values.joined(separator: separator)
    }
}
