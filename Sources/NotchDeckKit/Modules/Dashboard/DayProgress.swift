import Foundation

/// Fraction of the configured workday that has elapsed. Pure and tested.
public enum DayProgress {
    /// Returns nil before the workday starts; 1 when it's over.
    public static func fraction(
        now: Date, startHour: Int, endHour: Int, calendar: Calendar = .current
    ) -> Double? {
        let dayStart = calendar.startOfDay(for: now)
        let start = dayStart.addingTimeInterval(TimeInterval(startHour * 3600))
        let end = dayStart.addingTimeInterval(TimeInterval(endHour * 3600))
        guard end > start else { return nil }
        if now < start { return nil }
        if now >= end { return 1 }
        return now.timeIntervalSince(start) / end.timeIntervalSince(start)
    }
}
