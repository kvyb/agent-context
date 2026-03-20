import Foundation

struct MemoryQueryResponseLimiter: Sendable {
    private let maxApproximateResponseTokens: Int

    init(maxApproximateResponseTokens: Int) {
        self.maxApproximateResponseTokens = maxApproximateResponseTokens
    }

    func bounded(_ payload: MemoryQueryAnswerPayload) -> MemoryQueryAnswerPayload {
        var answer = payload.answer
        var keyPoints = payload.keyPoints
        var supportingEvents = payload.supportingEvents

        while approximateTokenCount(
            answer: answer,
            keyPoints: keyPoints,
            supportingEvents: supportingEvents
        ) > maxApproximateResponseTokens {
            if !supportingEvents.isEmpty {
                supportingEvents.removeLast()
                continue
            }
            if !keyPoints.isEmpty {
                keyPoints.removeLast()
                continue
            }
            let trimmed = trimmedText(answer, targetTokenBudget: maxApproximateResponseTokens - 64)
            if trimmed == answer {
                break
            }
            answer = trimmed
        }

        return MemoryQueryAnswerPayload(
            answer: answer,
            keyPoints: keyPoints,
            supportingEvents: supportingEvents,
            insufficientEvidence: payload.insufficientEvidence
        )
    }

    private func approximateTokenCount(
        answer: String,
        keyPoints: [String],
        supportingEvents: [String]
    ) -> Int {
        let aggregate = ([answer] + keyPoints + supportingEvents).joined(separator: "\n")
        return max(1, Int(ceil(Double(aggregate.count) / 4.0)))
    }

    private func trimmedText(_ text: String, targetTokenBudget: Int) -> String {
        let targetCharacters = max(160, targetTokenBudget * 4)
        guard text.count > targetCharacters else {
            return text
        }

        let cutoffIndex = text.index(text.startIndex, offsetBy: targetCharacters)
        let prefix = String(text[..<cutoffIndex])
        let candidate = prefix
            .split(separator: " ")
            .dropLast()
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? String(prefix) : candidate + "..."
    }
}
