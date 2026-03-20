import Foundation

struct MemoryQueryBudgetPolicy: Sendable {
    private let runtimeConfig: MemoryQueryRuntimeConfig

    init(runtimeConfig: MemoryQueryRuntimeConfig) {
        self.runtimeConfig = runtimeConfig
    }

    func overallDeadline(for options: MemoryQueryOptions) -> Date? {
        let requested = options.timeoutSeconds ?? runtimeConfig.timeoutSeconds
        guard let requested else {
            return nil
        }
        return Date().addingTimeInterval(max(1, requested))
    }

    func remainingSeconds(until deadline: Date?) -> TimeInterval {
        guard let deadline else {
            return .greatestFiniteMagnitude
        }
        return max(0, deadline.timeIntervalSinceNow)
    }

    func stageBudget(
        preferred: TimeInterval?,
        deadline: Date?,
        reserveSeconds: TimeInterval
    ) -> TimeInterval? {
        let remaining = remainingSeconds(until: deadline)
        if remaining == .greatestFiniteMagnitude {
            return preferred
        }

        let reserved = max(0, reserveSeconds)
        let protectedRemaining = max(0, remaining - reserved)
        if let preferred {
            if protectedRemaining >= 1 {
                return min(preferred, protectedRemaining)
            }
            return min(preferred, remaining)
        }
        if protectedRemaining >= 1 {
            return protectedRemaining
        }
        return remaining > 0 ? remaining : nil
    }

    func plannerReserveSeconds(request: MemoryQueryRequest, profile: QueryIntentProfile) -> TimeInterval {
        let detailedBuffer: TimeInterval = profile.prefersDetailedAnswer ? 1.5 : 0
        if profile.prefersLexicalFirst {
            let base: TimeInterval = request.options.includesSemanticSearch && request.options.includesLexicalSearch ? 3 : 2
            return base + detailedBuffer
        }
        let base: TimeInterval = request.options.includesSemanticSearch || request.options.includesLexicalSearch ? 2 : 0
        return base + detailedBuffer
    }

    func semanticReserveSeconds(request: MemoryQueryRequest, profile: QueryIntentProfile) -> TimeInterval {
        let detailedBuffer: TimeInterval = profile.prefersDetailedAnswer ? 0.75 : 0
        if profile.prefersLexicalFirst && request.options.includesLexicalSearch {
            return 1.5 + detailedBuffer
        }
        return (request.options.includesLexicalSearch ? 1 : 0.5) + detailedBuffer
    }

    func formattedSeconds(_ value: TimeInterval) -> String {
        String(format: "%.1fs", value)
    }
}
