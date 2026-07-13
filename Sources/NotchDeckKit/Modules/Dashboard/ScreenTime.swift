import AppKit
import SwiftUI

public struct UsageSlice: Equatable, Sendable {
    public var bundleID: String
    public var seconds: TimeInterval

    public init(bundleID: String, seconds: TimeInterval) {
        self.bundleID = bundleID
        self.seconds = seconds
    }
}

/// Per-day, per-app usage accumulation. Pure and tested.
public struct UsageLedger: Sendable {
    /// dayKey (yyyy-MM-dd) → bundleID → seconds
    public private(set) var days: [String: [String: TimeInterval]]

    public init(days: [String: [String: TimeInterval]] = [:]) {
        self.days = days
    }

    public static func dayKey(for date: Date) -> String {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    /// Credits `bundleID` with the interval, splitting across midnight.
    public mutating func record(bundleID: String, from start: Date, to end: Date) {
        guard end > start else { return }
        var cursor = start
        while cursor < end {
            let dayEnd = Calendar.current.startOfDay(for: cursor).addingTimeInterval(86_400)
            let sliceEnd = min(end, dayEnd)
            let key = Self.dayKey(for: cursor)
            days[key, default: [:]][bundleID, default: 0] += sliceEnd.timeIntervalSince(cursor)
            cursor = sliceEnd
        }
    }

    /// Today's top apps plus an "other" remainder.
    public func today(top count: Int, now: Date = Date()) -> [UsageSlice] {
        let usage = days[Self.dayKey(for: now)] ?? [:]
        let sorted = usage.sorted { $0.value > $1.value }
        var slices = sorted.prefix(count).map { UsageSlice(bundleID: $0.key, seconds: $0.value) }
        let rest = sorted.dropFirst(count).reduce(0) { $0 + $1.value }
        if rest > 0 {
            slices.append(UsageSlice(bundleID: "other", seconds: rest))
        }
        return slices
    }
}

/// Event-driven frontmost-app tracker — no polling.
@MainActor
final class AppUsageTracker: ObservableObject {
    @Published private(set) var todaySlices: [UsageSlice] = []

    private var ledger = UsageLedger()
    private var currentBundle: String?
    private var sinceDate = Date()
    private var observers: [NSObjectProtocol] = []
    private var persistTask: Task<Void, Never>?

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchDeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("screentime.json")
    }

    func activate() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode([String: [String: TimeInterval]].self, from: data) {
            ledger = UsageLedger(days: decoded)
        }
        currentBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        sinceDate = Date()

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let bundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .bundleIdentifier
            Task { @MainActor in AppUsageTrackerShared.instance?.transition(to: bundle) }
        })
        AppUsageTrackerShared.instance = self
        publish()
    }

    func deactivate() {
        transition(to: nil)
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver(_:))
        observers = []
        persistNow()
    }

    private func transition(to bundle: String?) {
        let now = Date()
        if let current = currentBundle {
            ledger.record(bundleID: current, from: sinceDate, to: now)
        }
        currentBundle = bundle
        sinceDate = now
        publish()
        schedulePersist()
    }

    private func publish() {
        // Include the in-progress span so the donut reflects "now".
        var snapshot = ledger
        if let current = currentBundle {
            snapshot.record(bundleID: current, from: sinceDate, to: Date())
        }
        todaySlices = snapshot.today(top: 5)
    }

    /// Called when the dashboard becomes visible, so the tile is current.
    func refresh() { publish() }

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.persistNow()
        }
    }

    private func persistNow() {
        if let data = try? JSONEncoder().encode(ledger.days) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }
}

@MainActor
enum AppUsageTrackerShared {
    weak static var instance: AppUsageTracker?
}

// MARK: - Donut tile

struct ScreenTimeTile: View {
    @ObservedObject var tracker: AppUsageTracker

    private static let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .gray]

    var body: some View {
        let slices = tracker.todaySlices
        let total = max(slices.reduce(0) { $0 + $1.seconds }, 1)

        HStack(spacing: 10) {
            donut(slices: slices, total: total)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text("Screen Time").font(.system(size: 10)).foregroundStyle(.secondary)
                Text(Self.duration(total))
                    .font(.system(size: 15, weight: .semibold))
                if let top = slices.first {
                    Text("\(Self.appName(top.bundleID)) \(Self.duration(top.seconds))")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
        .onAppear { tracker.refresh() }
    }

    private func donut(slices: [UsageSlice], total: TimeInterval) -> some View {
        ZStack {
            var start = -90.0
            ForEach(Array(slices.enumerated()), id: \.offset) { index, slice in
                let sweep = 360 * slice.seconds / total
                let trimFrom = (start + 90) / 360
                let trimTo = (start + 90 + sweep) / 360
                let _ = { start += sweep }()
                Circle()
                    .trim(from: trimFrom, to: max(trimFrom, trimTo - 0.005))
                    .stroke(
                        Self.palette[index % Self.palette.count],
                        style: StrokeStyle(lineWidth: 7, lineCap: .butt)
                    )
                    .rotationEffect(.degrees(-90))
            }
            if slices.isEmpty {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 7)
            }
        }
    }

    static func appName(_ bundleID: String) -> String {
        if bundleID == "other" { return "Other" }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
        }
        return bundleID.components(separatedBy: ".").last ?? bundleID
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
}
