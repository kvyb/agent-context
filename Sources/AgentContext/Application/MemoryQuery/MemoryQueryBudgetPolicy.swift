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

    func formattedSeconds(_ value: TimeInterval) -> String {
        String(format: "%.1fs", value)
    }
}
