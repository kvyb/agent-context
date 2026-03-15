import Foundation

struct MemoryQueryScopeParser: Sendable {
    private let calendar: Calendar

    init(calendar: Calendar = .autoupdatingCurrent) {
        self.calendar = calendar
    }

    func inferScope(for query: String, referenceDate: Date = Date()) -> MemoryQueryScope {
        if let explicit = explicitDateScope(for: query, referenceDate: referenceDate) {
            return explicit
        }

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

    func hasExplicitDate(in query: String) -> Bool {
        explicitDateScope(for: query, referenceDate: Date()) != nil
    }

    func normalizedQueries(for question: String, plannerQueries: [String]) -> [String] {
        let combined = plannerQueries + [question]
        var seen = Set<String>()
        var output: [String] = []

        for value in combined {
            guard let normalized = value.nilIfEmpty else { continue }
            let key = normalized.lowercased()
            if seen.insert(key).inserted {
                output.append(normalized)
            }
            if output.count >= 10 {
                break
            }
        }

        if output.isEmpty, let fallback = question.nilIfEmpty {
            output = [fallback]
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

    private func explicitDateScope(for query: String, referenceDate: Date) -> MemoryQueryScope? {
        let lowered = query.lowercased()
        let parsedDates = extractExplicitDates(from: query)
        guard !parsedDates.isEmpty else {
            return nil
        }

        if parsedDates.count >= 2 {
            let start = calendar.startOfDay(for: parsedDates[0])
            let secondStart = calendar.startOfDay(for: parsedDates[1])
            let orderedStart = min(start, secondStart)
            let orderedEnd = max(start, secondStart)
            let end = calendar.date(byAdding: .day, value: 1, to: orderedEnd)
            let label = "from \(dayLabel(orderedStart)) to \(dayLabel(orderedEnd))"
            return MemoryQueryScope(start: orderedStart, end: end, label: label)
        }

        guard let day = parsedDates.first else {
            return nil
        }

        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
        else {
            return nil
        }

        if lowered.contains("since"),
           let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: referenceDate)) {
            let label = "since \(dayLabel(dayStart))"
            return MemoryQueryScope(start: dayStart, end: end, label: label)
        }

        let label = lowered.contains("on ") ? "on \(dayLabel(dayStart))" : dayLabel(dayStart)
        return MemoryQueryScope(start: dayStart, end: dayEnd, label: label)
    }

    private func extractExplicitDates(from text: String) -> [Date] {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var results: [Date] = []
        var seen = Set<Int>()

        let patterns = [
            #"\b(20\d{2})-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])\b"#,
            #"\b(0?[1-9]|1[0-2])\/(0?[1-9]|[12]\d|3[01])\/(20\d{2})\b"#,
            #"\b(20\d{2})\/(0?[1-9]|1[0-2])\/(0?[1-9]|[12]\d|3[01])\b"#
        ]

        let formatters = [
            dateFormatter("yyyy-MM-dd"),
            dateFormatter("M/d/yyyy"),
            dateFormatter("yyyy/M/d")
        ]

        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let matches = regex.matches(in: text, options: [], range: fullRange)
            for match in matches {
                let raw = nsText.substring(with: match.range)
                guard let date = formatters[index].date(from: raw) else { continue }
                let dayKey = Int(calendar.startOfDay(for: date).timeIntervalSince1970 / 86_400)
                if seen.insert(dayKey).inserted {
                    results.append(date)
                }
            }
        }

        return results.sorted()
    }

    private func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func dateFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter
    }
}
