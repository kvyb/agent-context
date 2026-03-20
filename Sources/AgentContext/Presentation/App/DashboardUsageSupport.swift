import Foundation

struct DashboardUsageSupport: Sendable {
    func weekDaysContaining(_ day: Date) -> [Date] {
        var calendar = Calendar.autoupdatingCurrent
        calendar.firstWeekday = 2
        let startOfDay = calendar.startOfDay(for: day)
        let weekday = calendar.component(.weekday, from: startOfDay)
        let offset = (weekday + 5) % 7
        guard let weekStart = calendar.date(byAdding: .day, value: -offset, to: startOfDay) else {
            return [startOfDay]
        }

        return (0..<7).compactMap { index in
            calendar.date(byAdding: .day, value: index, to: weekStart)
        }
    }

    func aggregateHourlyUsage(from rows: [DashboardHourRow]) -> [DashboardHourUsage] {
        rows.sorted { $0.hour < $1.hour }.map { row in
            let total = row.blocks.reduce(0) { $0 + $1.duration }
            return DashboardHourUsage(id: row.hour, hour: row.hour, duration: total)
        }
    }

    func aggregateDayAppRows(from rows: [DashboardHourRow]) -> [DashboardDayAppRow] {
        var grouped: [String: DashboardDayAppRow] = [:]

        for row in rows {
            for block in row.blocks {
                let key = block.bundleID ?? block.appName
                if var existing = grouped[key] {
                    existing = DashboardDayAppRow(
                        id: existing.id,
                        appName: existing.appName,
                        bundleID: existing.bundleID,
                        duration: existing.duration + block.duration,
                        icon: existing.icon
                    )
                    grouped[key] = existing
                } else {
                    grouped[key] = DashboardDayAppRow(
                        id: key,
                        appName: block.appName,
                        bundleID: block.bundleID,
                        duration: block.duration,
                        icon: block.icon
                    )
                }
            }
        }

        return grouped.values.sorted { lhs, rhs in
            if abs(lhs.duration - rhs.duration) > 0.1 {
                return lhs.duration > rhs.duration
            }
            return lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending
        }
    }

    func totalDuration(from rows: [DashboardHourRow]) -> TimeInterval {
        rows.reduce(0) { accumulator, row in
            accumulator + row.blocks.reduce(0) { $0 + $1.duration }
        }
    }

    func elapsedText(from start: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let minutes = seconds / 60
        let remainder = seconds % 60
        return String(format: "%02d:%02d", minutes, remainder)
    }
}
