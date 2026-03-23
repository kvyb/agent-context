import Foundation

struct SQLiteBM25CallConversationSupport: Sendable {
    private let database: SQLiteStore

    init(database: SQLiteStore) {
        self.database = database
    }

    func anchoredScopeIfNeeded(
        baseScope: MemoryQueryScope,
        analysis: MemoryQueryQuestionAnalysis
    ) async -> MemoryQueryScope? {
        guard analysis.seeksCallConversation, analysis.mentionsZoom, !analysis.personTerms.isEmpty else {
            return nil
        }

        let anchors: [Date]
        do {
            anchors = try await database.findArtifactCaptureTimes(
                appNameLike: "zoom",
                textTerms: analysis.personTerms,
                start: baseScope.start,
                end: baseScope.end,
                limit: 256
            )
        } catch {
            return nil
        }

        guard let minAnchor = anchors.min(), let maxAnchor = anchors.max() else {
            return nil
        }

        return MemoryQueryScope(
            start: minAnchor.addingTimeInterval(-5 * 60),
            end: maxAnchor.addingTimeInterval(15 * 60),
            label: "anchored_call"
        )
    }

    func alignedRows(
        taskSegments: [TaskSegmentRecord],
        transcriptUnits: [TranscriptUnitRecord],
        artifactPerceptions: [StoredEvidenceRecord],
        memoryRows: [MemoryRecord],
        analysis: MemoryQueryQuestionAnalysis
    ) -> SQLiteBM25CallAlignedRows {
        guard analysis.seeksCallConversation, !analysis.personTerms.isEmpty else {
            return SQLiteBM25CallAlignedRows(
                taskSegments: taskSegments,
                transcriptUnits: transcriptUnits,
                artifactPerceptions: artifactPerceptions,
                memoryRows: memoryRows
            )
        }

        let personAnchors = participantAnchorTimes(rows: artifactPerceptions, analysis: analysis)
        guard !personAnchors.isEmpty else {
            return SQLiteBM25CallAlignedRows(
                taskSegments: taskSegments,
                transcriptUnits: transcriptUnits,
                artifactPerceptions: artifactPerceptions,
                memoryRows: memoryRows
            )
        }

        return SQLiteBM25CallAlignedRows(
            taskSegments: taskSegments.filter { segment in
                isNearParticipantAnchor(segment.occurredAt, anchors: personAnchors)
                    && segment.appName?.lowercased().contains("zoom") == true
            },
            transcriptUnits: transcriptUnits.filter {
                isCallAlignedTranscriptUnit($0, anchors: personAnchors, analysis: analysis)
            },
            artifactPerceptions: artifactPerceptions.filter { row in
                isNearParticipantAnchor(row.metadata.capturedAt, anchors: personAnchors)
                    && isCallAlignedArtifact(row, analysis: analysis)
            },
            memoryRows: []
        )
    }

    func scopedHits(
        _ hits: [MemoryEvidenceHit],
        analysis: MemoryQueryQuestionAnalysis,
        limit: Int
    ) -> [MemoryEvidenceHit] {
        guard !hits.isEmpty else {
            return []
        }

        let direct = hits.filter { isDirectCallEvidence($0, analysis: analysis) }
        guard !direct.isEmpty else {
            return Array(hits.prefix(limit))
        }

        let anchorTimes = direct.compactMap(\.occurredAt)
        let supplementary = hits.filter { hit in
            guard !direct.contains(where: { $0.id == hit.id }) else {
                return false
            }
            guard isNearCallAnchor(hit, anchorTimes: anchorTimes) else {
                return false
            }
            guard !isIndirectWorkContext(hit) else {
                return false
            }
            guard sharesCallMedium(hit) else {
                return false
            }
            return matchesCallParticipantContext(hit, analysis: analysis) || isZoomScoped(hit)
        }

        var output: [MemoryEvidenceHit] = []
        var seen = Set<String>()
        for hit in direct + supplementary {
            guard seen.insert(hit.id).inserted else { continue }
            output.append(hit)
            if output.count >= limit {
                break
            }
        }
        return output
    }

    private func isDirectCallEvidence(
        _ hit: MemoryEvidenceHit,
        analysis: MemoryQueryQuestionAnalysis
    ) -> Bool {
        let unit = LexicalRetrievalUnit(rawValue: hit.metadata["retrieval_unit"] ?? "") ?? .memorySummary
        switch unit {
        case .transcriptUnit, .transcriptChunk:
            return sharesCallMedium(hit)
                && (isZoomScoped(hit) || matchesCallParticipantContext(hit, analysis: analysis))
        case .artifactEvidence:
            return sharesCallMedium(hit) && isZoomScoped(hit)
        case .taskSegment, .memorySummary:
            return analysis.personTerms.isEmpty
                && sharesCallMedium(hit)
                && isZoomScoped(hit)
        }
    }

    private func isIndirectWorkContext(_ hit: MemoryEvidenceHit) -> Bool {
        let unit = LexicalRetrievalUnit(rawValue: hit.metadata["retrieval_unit"] ?? "") ?? .memorySummary
        switch unit {
        case .taskSegment, .memorySummary:
            return true
        case .artifactEvidence, .transcriptChunk, .transcriptUnit:
            return false
        }
    }

    private func isNearCallAnchor(_ hit: MemoryEvidenceHit, anchorTimes: [Date]) -> Bool {
        guard let occurredAt = hit.occurredAt else {
            return false
        }
        return anchorTimes.contains { abs($0.timeIntervalSince(occurredAt)) <= 20 * 60 }
    }

    private func matchesCallParticipantContext(
        _ hit: MemoryEvidenceHit,
        analysis: MemoryQueryQuestionAnalysis
    ) -> Bool {
        let searchable = (
            hit.text
            + " "
            + (hit.metadata["people"] ?? "")
            + " "
            + (hit.metadata["entities"] ?? "")
            + " "
            + (hit.appName ?? "")
            + " "
            + (hit.project ?? "")
        ).lowercased()
        return analysis.callParticipantTerms.contains(where: { searchable.contains($0) })
    }

    private func isZoomScoped(_ hit: MemoryEvidenceHit) -> Bool {
        let searchable = (
            hit.text
            + " "
            + (hit.appName ?? "")
            + " "
            + hit.metadata.values.joined(separator: " ")
        ).lowercased()
        return searchable.contains("zoom")
            || searchable.contains("zoom.us")
            || searchable.contains("video call")
            || searchable.contains("video conference")
    }

    private func sharesCallMedium(_ hit: MemoryEvidenceHit) -> Bool {
        let searchable = (
            hit.text
            + " "
            + (hit.appName ?? "")
            + " "
            + (hit.metadata["app_name"] ?? "")
            + " "
            + (hit.metadata["workspace"] ?? "")
            + " "
            + (hit.metadata["window_title"] ?? "")
        ).lowercased()

        return searchable.contains("zoom")
            || searchable.contains("zoom.us")
            || searchable.contains("meeting")
            || searchable.contains("video call")
    }

    private func isCallAlignedTranscriptUnit(
        _ unit: TranscriptUnitRecord,
        anchors: [Date],
        analysis: MemoryQueryQuestionAnalysis
    ) -> Bool {
        guard isNearParticipantAnchor(unit.occurredAt, anchors: anchors) else {
            return false
        }

        let searchable = (
            (unit.appName ?? "")
            + " "
            + (unit.workspace ?? "")
            + " "
            + unit.people.joined(separator: " ")
            + " "
            + unit.entities.joined(separator: " ")
            + " "
            + unit.summary
            + " "
            + unit.excerptText
        ).lowercased()

        if searchable.contains("zoom") || searchable.contains("zoom.us") || searchable.contains("video call") {
            return true
        }

        if analysis.mentionsZoom {
            return false
        }

        return analysis.personTerms.contains(where: { searchable.contains($0) })
    }

    private func isCallAlignedArtifact(
        _ row: StoredEvidenceRecord,
        analysis: MemoryQueryQuestionAnalysis
    ) -> Bool {
        guard row.metadata.kind == .audio || isZoomArtifact(row) else {
            return false
        }

        let searchable = [
            row.metadata.app.appName,
            row.metadata.window.workspace,
            row.metadata.window.title,
            row.analysis?.workspace,
            row.analysis?.description,
            row.analysis?.contentDescription,
            row.analysis?.transcript,
            row.analysis?.entities.joined(separator: " ")
        ]
        .compactMap { $0?.nilIfEmpty }
        .joined(separator: " ")
        .lowercased()

        if searchable.contains("zoom") || searchable.contains("zoom.us") || searchable.contains("video call") {
            return true
        }

        if analysis.mentionsZoom {
            return false
        }

        return analysis.personTerms.contains(where: { searchable.contains($0) })
    }

    private func participantAnchorTimes(
        rows: [StoredEvidenceRecord],
        analysis: MemoryQueryQuestionAnalysis
    ) -> [Date] {
        var anchors: [Date] = []
        for row in rows {
            guard isZoomArtifact(row) else {
                continue
            }

            let analysisText = [
                row.analysis?.description,
                row.analysis?.contentDescription,
                row.analysis?.layoutDescription,
                row.analysis?.salientText.joined(separator: " "),
                row.analysis?.entities.joined(separator: " "),
                row.analysis?.evidence.joined(separator: " "),
                row.metadata.window.title
            ]
            .compactMap { $0?.nilIfEmpty }
            .joined(separator: " ")
            .lowercased()

            guard analysis.personTerms.contains(where: { analysisText.contains($0) }) else {
                continue
            }

            anchors.append(row.metadata.capturedAt)
        }
        return anchors
    }

    private func isNearParticipantAnchor(_ timestamp: Date, anchors: [Date]) -> Bool {
        anchors.contains { abs($0.timeIntervalSince(timestamp)) <= 20 * 60 }
    }

    private func isZoomArtifact(_ row: StoredEvidenceRecord) -> Bool {
        let searchable = (
            row.metadata.app.appName
            + " "
            + (row.metadata.window.workspace ?? "")
            + " "
            + (row.metadata.window.title ?? "")
            + " "
            + (row.analysis?.workspace ?? "")
        ).lowercased()

        return searchable.contains("zoom")
            || searchable.contains("zoom.us")
            || searchable.contains("video conference")
            || searchable.contains("meeting")
    }
}

struct SQLiteBM25CallAlignedRows {
    let taskSegments: [TaskSegmentRecord]
    let transcriptUnits: [TranscriptUnitRecord]
    let artifactPerceptions: [StoredEvidenceRecord]
    let memoryRows: [MemoryRecord]
}

private extension MemoryQueryQuestionAnalysis {
    var callParticipantTerms: [String] {
        var seen = Set<String>()
        return (personTerms + focusTerms).compactMap { term in
            let normalized = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, seen.insert(normalized).inserted else {
                return nil
            }
            return normalized
        }
    }
}
