import Foundation

struct MemoryQueryEvaluationFormatter: Sendable {
    func render(_ report: MemoryQueryEvaluationReport, as format: MemoryQueryOutputFormat) -> String {
        switch format {
        case .json:
            return renderJSON(report)
        case .text:
            return renderText(report)
        }
    }

    private func renderJSON(_ report: MemoryQueryEvaluationReport) -> String {
        let iso = ISO8601DateFormatter()
        let trace = report.trace
        let preview = retrievalPreview(for: report)

        var object: [String: Any] = [
            "query": trace.result.query,
            "latency_seconds": report.latencySeconds,
            "answer_origin": trace.answerOrigin.rawValue,
            "query_result": [
                "answer": trace.result.answer,
                "key_points": trace.result.keyPoints,
                "supporting_events": trace.result.supportingEvents,
                "insufficient_evidence": trace.result.insufficientEvidence,
                "sources": [
                    "mem0_semantic_count": trace.result.mem0SemanticCount,
                    "bm25_store_count": trace.result.bm25StoreCount
                ],
                "time_scope": [
                    "start": trace.result.scope.start.map { iso.string(from: $0) } ?? "",
                    "end": trace.result.scope.end.map { iso.string(from: $0) } ?? "",
                    "label": trace.result.scope.label ?? ""
                ]
            ],
            "retrieval_preview": preview
        ]

        if let evaluation = report.evaluation {
            object["evaluation"] = [
                "overall_score": evaluation.overallScore,
                "query_alignment_score": evaluation.queryAlignmentScore,
                "retrieval_relevance_score": evaluation.retrievalRelevanceScore,
                "retrieval_coverage_score": evaluation.retrievalCoverageScore,
                "groundedness_score": evaluation.groundednessScore,
                "answer_completeness_score": evaluation.answerCompletenessScore,
                "summary": evaluation.summary,
                "retrieval_explanation": evaluation.retrievalExplanation,
                "groundedness_explanation": evaluation.groundednessExplanation,
                "answer_quality_explanation": evaluation.answerQualityExplanation,
                "strengths": evaluation.strengths,
                "weaknesses": evaluation.weaknesses,
                "improvement_actions": evaluation.improvementActions,
                "evidence_gaps": evaluation.evidenceGaps
            ]
        }

        if let evaluationError = report.evaluationError {
            object["evaluation_error"] = evaluationError
        }

        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let rendered = String(data: data, encoding: .utf8) {
            return rendered
        }

        return "{\"error\":\"serialization_failed\"}"
    }

    private func renderText(_ report: MemoryQueryEvaluationReport) -> String {
        let trace = report.trace
        var lines: [String] = []
        lines.append("Query: \(trace.result.query)")
        lines.append("Latency: \(String(format: "%.2fs", report.latencySeconds))")
        lines.append("Answer origin: \(trace.answerOrigin.rawValue)")
        lines.append("Evidence counts: mem0=\(trace.result.mem0SemanticCount) bm25=\(trace.result.bm25StoreCount)")
        lines.append("")
        lines.append("Answer:")
        lines.append(trace.result.answer)

        if let evaluation = report.evaluation {
            lines.append("")
            lines.append("Evaluation:")
            lines.append("Overall: \(evaluation.overallScore)/100")
            lines.append("Query alignment: \(evaluation.queryAlignmentScore)/5")
            lines.append("Retrieval relevance: \(evaluation.retrievalRelevanceScore)/5")
            lines.append("Retrieval coverage: \(evaluation.retrievalCoverageScore)/5")
            lines.append("Groundedness: \(evaluation.groundednessScore)/5")
            lines.append("Answer completeness: \(evaluation.answerCompletenessScore)/5")
            lines.append("")
            lines.append("Summary: \(evaluation.summary)")
            lines.append("Retrieval: \(evaluation.retrievalExplanation)")
            lines.append("Groundedness: \(evaluation.groundednessExplanation)")
            lines.append("Answer quality: \(evaluation.answerQualityExplanation)")
            lines.append("")
            lines.append("Strengths:")
            evaluation.strengths.forEach { lines.append("- \($0)") }
            lines.append("Weaknesses:")
            evaluation.weaknesses.forEach { lines.append("- \($0)") }
            lines.append("Improvement actions:")
            evaluation.improvementActions.forEach { lines.append("- \($0)") }
            lines.append("Evidence gaps:")
            evaluation.evidenceGaps.forEach { lines.append("- \($0)") }
        } else if let error = report.evaluationError {
            lines.append("")
            lines.append("Evaluation unavailable: \(error)")
        }

        let preview = retrievalPreview(for: report)
        if !preview.isEmpty {
            lines.append("")
            lines.append("Retrieval preview:")
            preview.forEach { lines.append("- \($0)") }
        }

        return lines.joined(separator: "\n")
    }

    private func retrievalPreview(for report: MemoryQueryEvaluationReport) -> [String] {
        let ordered = (report.trace.bm25Evidence + report.trace.mem0Evidence)
            .sorted {
                if abs($0.hybridScore - $1.hybridScore) > 0.0001 {
                    return $0.hybridScore > $1.hybridScore
                }
                return ($0.occurredAt ?? .distantPast) > ($1.occurredAt ?? .distantPast)
            }
            .prefix(12)
        return ordered.map { hit in
            let timestamp = hit.occurredAt.map {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = .autoupdatingCurrent
                formatter.dateFormat = "yyyy-MM-dd HH:mm"
                return formatter.string(from: $0)
            } ?? "unknown-time"
            return "[\(timestamp)] \(hit.source.rawValue) \(hit.text)"
        }
    }
}
