import Foundation

/// Pure math mapping today's events onto a 0…1 working-day timeline.
public enum DayTimeline {
    public struct Block: Equatable, Sendable {
        public var startFraction: Double
        public var endFraction: Double

        public init(startFraction: Double, endFraction: Double) {
            self.startFraction = startFraction
            self.endFraction = endFraction
        }
    }

    /// Fraction of `dayStart`…`dayEnd` at which `date` falls, or nil if
    /// `date` is outside that range (or the range is empty/inverted).
    public static func fraction(of date: Date, dayStart: Date, dayEnd: Date) -> Double? {
        let total = dayEnd.timeIntervalSince(dayStart)
        guard total > 0 else { return nil }
        let f = date.timeIntervalSince(dayStart) / total
        return (0...1).contains(f) ? f : nil
    }

    /// Maps events onto the 0…1 timeline, clamping partial overlaps to the
    /// range and dropping events that are zero-length or fall entirely
    /// outside `dayStart`…`dayEnd`.
    public static func blocks(
        events: [(start: Date, end: Date)], dayStart: Date, dayEnd: Date
    ) -> [Block] {
        let total = dayEnd.timeIntervalSince(dayStart)
        guard total > 0 else { return [] }
        return events.compactMap { event in
            let s = max(0, event.start.timeIntervalSince(dayStart) / total)
            let e = min(1, event.end.timeIntervalSince(dayStart) / total)
            guard e > s, s < 1, e > 0 else { return nil }
            return Block(startFraction: s, endFraction: e)
        }
    }
}
