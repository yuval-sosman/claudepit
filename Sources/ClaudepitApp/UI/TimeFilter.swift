import Foundation

enum TimePreset: String, CaseIterable {
    case today   = "Today"
    case week    = "7d"
    case month   = "30d"
    case quarter = "3m"

    var label: String { rawValue }

    var startDate: Date {
        let cal = Calendar.current
        let now = Date()
        switch self {
        case .today:   return cal.startOfDay(for: now)
        case .week:    return cal.date(byAdding: .day, value: -7, to: now)!
        case .month:   return cal.date(byAdding: .day, value: -30, to: now)!
        case .quarter: return cal.date(byAdding: .day, value: -90, to: now)!
        }
    }
}

enum TimeFilter: Equatable {
    case all
    case preset(TimePreset)
    case custom(from: Date, to: Date)

    var isActive: Bool {
        if case .all = self { return false }
        return true
    }

    var label: String {
        switch self {
        case .all:           return "All"
        case .preset(let p): return p.label
        case .custom:        return "Custom"
        }
    }

    func includes(_ date: Date) -> Bool {
        switch self {
        case .all:
            return true
        case .preset(let p):
            return date >= p.startDate
        case .custom(let from, let to):
            let endOfTo = Calendar.current.date(byAdding: .day, value: 1, to: to)!
            return date >= from && date < endOfTo
        }
    }
}
