import Foundation

struct MemoryQueryScopeParser: Sendable {
    private let calendar: Calendar

    init(calendar: Calendar = .autoupdatingCurrent) {
        self.calendar = calendar
    }

    func inferScope(for query: String, referenceDate: Date = Date()) -> MemoryQueryScope {
        let lowered = query.lowercased()
        let todayStart = calendar.startOfDay(for: referenceDate)

        if lowered.contains("today") {
            let end = calendar.date(byAdding: .day, value: 1, to: todayStart)
            return MemoryQueryScope(start: todayStart, end: end, label: "today")
        }

        if lowered.contains("yesterday"),
           let start = calendar.date(byAdding: .day, value: -1, to: todayStart),
           let end = calendar.date(byAdding: .day, value: 1, to: start) {
            return MemoryQueryScope(start: start, end: end, label: "yesterday")
        }

        if lowered.contains("this week"),
           let start = weekStart(containing: referenceDate),
           let end = calendar.date(byAdding: .day, value: 7, to: start) {
            return MemoryQueryScope(start: start, end: end, label: "this week")
        }

        if lowered.contains("last week"),
           let thisWeekStart = weekStart(containing: referenceDate),
           let start = calendar.date(byAdding: .day, value: -7, to: thisWeekStart) {
            return MemoryQueryScope(start: start, end: thisWeekStart, label: "last week")
        }

        if lowered.contains("this month"),
           let interval = calendar.dateInterval(of: .month, for: referenceDate) {
            return MemoryQueryScope(start: interval.start, end: interval.end, label: "this month")
        }

        if lowered.contains("last month"),
           let thisMonth = calendar.dateInterval(of: .month, for: referenceDate),
           let start = calendar.date(byAdding: .month, value: -1, to: thisMonth.start) {
            return MemoryQueryScope(start: start, end: thisMonth.start, label: "last month")
        }

        let weekdays: [(String, Int)] = [
            ("monday", 2),
            ("tuesday", 3),
            ("wednesday", 4),
            ("thursday", 5),
            ("friday", 6),
            ("saturday", 7),
            ("sunday", 1)
        ]

        for (name, weekday) in weekdays where lowered.contains(name) {
            if let dayStart = mostRecent(weekday: weekday, referenceDate: referenceDate),
               let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) {
                return MemoryQueryScope(start: dayStart, end: dayEnd, label: name)
            }
        }

        return MemoryQueryScope(start: nil, end: nil, label: nil)
    }

    func normalizedQueries(for question: String, plannerQueries: [String]) -> [String] {
        let extracted = keywordTerms(from: question)
        let combined = plannerQueries + extracted + [question]
        var seen = Set<String>()
        var output: [String] = []

        for value in combined {
            guard let normalized = value.nilIfEmpty else { continue }
            let key = normalized.lowercased()
            if seen.insert(key).inserted {
                output.append(normalized)
            }
            if output.count >= 8 {
                break
            }
        }

        return output
    }

    func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
    }

    func queryTerms(for text: String) -> [String] {
        let stopWords: Set<String> = [
            "what", "did", "do", "i", "in", "on", "at", "the", "a", "an", "for", "to",
            "of", "from", "and", "or", "my", "was", "were", "is", "are", "this", "that",
            "with", "during", "show", "me", "about", "when", "where", "how", "status",
            "week", "today", "yesterday", "month"
        ]
        return tokenize(text).filter { !stopWords.contains($0) }
    }

    private func keywordTerms(from query: String) -> [String] {
        let terms = queryTerms(for: query)
        var output: [String] = []
        var seen = Set<String>()
        for term in terms where seen.insert(term).inserted {
            output.append(term)
            if output.count >= 6 {
                break
            }
        }
        return output
    }

    private func weekStart(containing date: Date) -> Date? {
        var weekCalendar = calendar
        weekCalendar.firstWeekday = 2
        let dayStart = weekCalendar.startOfDay(for: date)
        let weekday = weekCalendar.component(.weekday, from: dayStart)
        let offset = (weekday + 5) % 7
        return weekCalendar.date(byAdding: .day, value: -offset, to: dayStart)
    }

    private func mostRecent(weekday: Int, referenceDate: Date) -> Date? {
        let today = calendar.startOfDay(for: referenceDate)
        let todayWeekday = calendar.component(.weekday, from: today)
        var delta = todayWeekday - weekday
        if delta < 0 {
            delta += 7
        }
        return calendar.date(byAdding: .day, value: -delta, to: today)
    }
}
