import Foundation

/// Groups dated items under the headers every dated list in the app uses — Today · Yesterday ·
/// Previous 7 Days · Previous 30 Days, then one section per month ("August", or "August 2025"
/// outside the current year). Shared by the Sessions, Plans and Memory lists so the three can't
/// draw the same day under two different headers.
public enum DateSections {
    public struct Section<Item>: Identifiable {
        public let id: String
        public let title: String
        public var items: [Item]
    }

    /// Items run newest first within a section (ties keep their incoming order); sections run
    /// newest first.
    public static func group<Item>(_ items: [Item], date: (Item) -> Date, now: Date,
                                   calendar: Calendar = .current) -> [Section<Item>] {
        var order: [String] = []
        var byID: [String: Section<Item>] = [:]
        let today = calendar.startOfDay(for: now)
        let bounds = [1, 7, 30].map { calendar.date(byAdding: .day, value: -$0, to: today)! }
        let sorted = items.enumerated().sorted { a, b in
            let da = date(a.element), db = date(b.element)
            return da != db ? da > db : a.offset < b.offset
        }
        for (_, item) in sorted {
            let d = date(item)
            let id = bucketID(for: d, today: today, bounds: bounds, calendar: calendar)
            if byID[id] == nil {
                order.append(id)
                byID[id] = Section(id: id, title: title(of: id, date: d, now: now, calendar: calendar), items: [])
            }
            byID[id]!.items.append(item)
        }
        return order.compactMap { byID[$0] }
    }

    /// Cheap per item; the (formatter-built) title is made once per section.
    private static func bucketID(for date: Date, today: Date, bounds: [Date], calendar: Calendar) -> String {
        if date >= today { return "today" }
        if date >= bounds[0] { return "yesterday" }
        if date >= bounds[1] { return "week" }
        if date >= bounds[2] { return "month" }
        let c = calendar.dateComponents([.year, .month], from: date)
        return "m\(c.year ?? 0)-\(c.month ?? 0)"
    }

    private static func title(of id: String, date: Date, now: Date, calendar: Calendar) -> String {
        switch id {
        case "today": return "Today"
        case "yesterday": return "Yesterday"
        case "week": return "Previous 7 Days"
        case "month": return "Previous 30 Days"
        default:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            let f = DateFormatter()
            f.calendar = calendar
            f.locale = calendar.locale ?? .current
            f.timeZone = calendar.timeZone
            f.setLocalizedDateFormatFromTemplate(sameYear ? "MMMM" : "MMMM y")
            return f.string(from: date)
        }
    }
}
