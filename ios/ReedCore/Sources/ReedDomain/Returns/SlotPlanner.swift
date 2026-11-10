import Foundation

public struct CardReturnSettings: Codable, Equatable, Sendable {
    public let cardID: UUID
    public var notificationsEnabled = true
    public var minutes: [Int] = []
    public var weekdays: Set<Int> = Set(1...7)
    public init(cardID: UUID) { self.cardID = cardID }
    public func validate() throws {
        guard minutes.count <= 10, Set(minutes).count == minutes.count, minutes.allSatisfy({ (0...1439).contains($0) }),
              weekdays.isSubset(of: Set(1...7)) else { throw ReturnError.invalidSchedule }
    }
}
public struct ReturnTimeSlot: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let date: Date
    public let explicitCardID: UUID?
    public init(id: String, date: Date, explicitCardID: UUID? = nil) { self.id = id; self.date = date; self.explicitCardID = explicitCardID }
}

public enum SlotPlanner {
    public static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)@\(calendar.timeZone.identifier)"
    }
    public static func slots(day: Date, seed: UInt64, settings: ReturnSettings,
                             explicit: [CardReturnSettings], calendar: Calendar) throws -> [ReturnTimeSlot] {
        try settings.validate()
        guard settings.enabled, settings.notificationsEnabled,
              settings.weekdays.contains(calendar.component(.weekday, from: day)) else { return [] }
        let key = dayKey(day, calendar: calendar), interval = Double(settings.minimumIntervalMinutes * 60)
        func date(_ minute: Int) -> Date? {
            guard let value = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0,
                of: day, matchingPolicy: .nextTime, repeatedTimePolicy: .first), calendar.isDate(value, inSameDayAs: day) else { return nil }
            return value
        }
        var chosen: [ReturnTimeSlot] = []
        for rule in explicit.sorted(by: { $0.cardID.uuidString < $1.cardID.uuidString }) where rule.notificationsEnabled {
            try rule.validate()
            guard rule.weekdays.contains(calendar.component(.weekday, from: day)) else { continue }
            for minute in rule.minutes.sorted() {
                guard let time = date(minute) else { continue }
                guard chosen.allSatisfy({ abs($0.date.timeIntervalSince(time)) >= interval }) else { throw ReturnError.conflictingExplicitTimes }
                chosen.append(ReturnTimeSlot(id: "\(key).e.\(rule.cardID).\(minute)", date: time, explicitCardID: rule.cardID))
            }
        }
        guard chosen.count <= settings.dailyLimit else { throw ReturnError.tooManyExplicitTimes }
        let count = settings.dailyLimit
        let margin = min(settings.jitterMinutes, (settings.lastMinute - settings.firstMinute) / 2)
        let first = settings.firstMinute + margin, last = settings.lastMinute - margin
        for index in 0..<count where chosen.count < count {
            let center = count == 1 ? (first + last) / 2 : first + (last - first) * index / (count - 1)
            let spread = settings.jitterMinutes
            let random = Int(stableHash("\(seed).\(index)") % UInt64(spread * 2 + 1)) - spread
            let preferred = max(settings.firstMinute, min(settings.lastMinute, center + random))
            // Closest available minute preserves the requested interval around explicit appointments.
            let minutes = (settings.firstMinute...settings.lastMinute).sorted {
                let left = abs($0 - preferred), right = abs($1 - preferred)
                return left == right ? $0 < $1 : left < right
            }
            if let time = minutes.lazy.compactMap({ date($0) }).first(where: { time in chosen.allSatisfy { abs($0.date.timeIntervalSince(time)) >= interval } }) {
                chosen.append(ReturnTimeSlot(id: "\(key).a.\(index).\(Int(time.timeIntervalSince1970))", date: time))
            }
        }
        return chosen.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
    }

    public static func stableHash(_ text: String) -> UInt64 {
        text.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }
}
