import Foundation

extension Calendar {
    func floorToTenMinute(_ date: Date) -> Date {
        var components = dateComponents([.year, .month, .day, .hour, .minute], from: date)
        components.minute = ((components.minute ?? 0) / 10) * 10
        components.second = 0
        return self.date(from: components) ?? date
    }

    func hourStart(for date: Date) -> Date {
        dateInterval(of: .hour, for: date)?.start ?? date
    }
}

extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
