import Foundation

/// A single time-of-day → profile mapping used by ``ProfileSchedule``.
public struct ProfileRule: Codable, Equatable, Sendable {
    public var minuteOfDay: Int
    public var profile: String

    public init(minuteOfDay: Int, profile: String) {
        self.minuteOfDay = minuteOfDay
        self.profile = profile
    }
}

/// Pure lookup: which profile should be active for a given minute-of-day.
public enum ProfileSchedule {
    /// Latest rule at/before `minute`; wraps to the day's last rule overnight.
    /// Returns `nil` when `rules` is empty.
    public static func active(atMinuteOfDay minute: Int, rules: [ProfileRule]) -> String? {
        guard !rules.isEmpty else { return nil }
        let sorted = rules.sorted { $0.minuteOfDay < $1.minuteOfDay }
        return (sorted.last { $0.minuteOfDay <= minute } ?? sorted.last)?.profile
    }
}
