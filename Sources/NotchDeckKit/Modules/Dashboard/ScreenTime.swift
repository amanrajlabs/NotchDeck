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
    @Published private(set) var todaySwitchCount = 0

    private var ledger = UsageLedger()
    private var currentBundle: String?
    private var sinceDate = Date()
    private var observers: [NSObjectProtocol] = []
    private var persistTask: Task<Void, Never>?
    private var switchCounts: [String: Int] = [:] // dayKey → count

    /// Ref-counted lifecycle: DashboardModule and ScreenTimeModule both keep
    /// this tracker alive independently (either can be enabled without the
    /// other), so activation/teardown only happen on the 0→1 / 1→0 edge —
    /// never double-registers the notification observer.
    private var activationCount = 0

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchDeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("screentime.json")
    }

    private static var switchesURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("screentime-switches.json")
    }

    /// Retains the shared tracker; only performs real activation on 0→1.
    func retain() {
        activationCount += 1
        guard activationCount == 1 else { return }
        activate()
    }

    /// Releases the shared tracker; only performs real teardown on 1→0.
    func release() {
        guard activationCount > 0 else { return }
        activationCount -= 1
        guard activationCount == 0 else { return }
        deactivate()
    }

    private func activate() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode([String: [String: TimeInterval]].self, from: data) {
            ledger = UsageLedger(days: decoded)
        }
        switchCounts = (try? Data(contentsOf: Self.switchesURL))
            .flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
        switchCounts = Self.prunedSwitchCounts(switchCounts)
        todaySwitchCount = switchCounts[UsageLedger.dayKey(for: Date())] ?? 0
        currentBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        sinceDate = Date()

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let bundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .bundleIdentifier
            Task { @MainActor in
                AppUsageTrackerShared.instance?.transition(to: bundle)
                AppUsageTrackerShared.instance?.recordSwitch()
            }
        })
        AppUsageTrackerShared.instance = self
        publish()
    }

    private func deactivate() {
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

    /// Ranked usage slices for today (no "in-progress" bias applied beyond `publish()`).
    func topSlices(_ count: Int) -> [UsageSlice] { ledger.today(top: count) }

    /// Counts one frontmost-app switch for today's tally and persists it.
    /// Only invoked from the activation-notification handler — never from
    /// `deactivate()`'s bookkeeping `transition(to: nil)` — so app-quit/module
    /// teardown doesn't inflate the switch count.
    private func recordSwitch() {
        let key = UsageLedger.dayKey(for: Date())
        switchCounts[key, default: 0] += 1
        todaySwitchCount = switchCounts[key] ?? 0
        switchCounts = Self.prunedSwitchCounts(switchCounts)
        if let data = try? JSONEncoder().encode(switchCounts) {
            try? data.write(to: Self.switchesURL, options: .atomic)
        }
    }

    /// Keeps only the most recent ~90 day-keys (dayKey sorts lexically = chronologically),
    /// so screentime-switches.json doesn't grow unbounded across months of use.
    private static func prunedSwitchCounts(_ counts: [String: Int]) -> [String: Int] {
        let keep = Set(counts.keys.sorted().suffix(90))
        return counts.filter { keep.contains($0.key) }
    }

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.persistNow()
        }
    }

    private func persistNow() {
        // Keep the file bounded: day keys sort lexicographically.
        let keep = Set(ledger.days.keys.sorted().suffix(30))
        let bounded = ledger.days.filter { keep.contains($0.key) }
        if let data = try? JSONEncoder().encode(bounded) {
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

    static let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .gray]

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

// MARK: - Screen Time module (categories, ranked apps, switch count)

@MainActor
final class ScreenTimeModule: NotchModule, ObservableObject {
    static let moduleID = "screentime"
    let id = ScreenTimeModule.moduleID
    let name = "Screen Time"
    let icon = "hourglass"
    let hasPanel = true
    var preferredHeight: CGFloat { 200 }

    let tracker: AppUsageTracker

    init(tracker: AppUsageTracker) {
        self.tracker = tracker
    }

    // Tracker is shared with DashboardModule; ref-counted retain/release lets
    // either module keep it alive independently without double-registering
    // the frontmost-app observer (see AppUsageTracker.retain/release).
    func activate() { tracker.retain() }
    func deactivate() { tracker.release() }

    func panelView() -> AnyView { AnyView(ScreenTimePanelView(tracker: tracker)) }

    func headerBadge() -> AnyView? {
        AnyView(HeaderPill(text: "\(tracker.todaySwitchCount) switches", icon: "arrow.triangle.swap"))
    }
}

struct ScreenTimePanelView: View {
    @ObservedObject var tracker: AppUsageTracker

    var body: some View {
        let slices = tracker.topSlices(8)
        let total = max(slices.reduce(0) { $0 + $1.seconds }, 1)
        let categories = AppCategory.totals(slices)
        HStack(alignment: .top, spacing: 20) {
            VStack(spacing: 8) {
                UsageDonut(slices: slices, total: total, centerText: ScreenTimeTile.duration(total))
                    .frame(width: 84, height: 84)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(categories.prefix(4).enumerated()), id: \.offset) { _, entry in
                        HStack(spacing: 5) {
                            Text(entry.category).font(.system(size: 9))
                            Spacer()
                            Text(ScreenTimeTile.duration(entry.seconds))
                                .font(.system(size: 9).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 130)
            }
            VStack(alignment: .leading, spacing: 4) {
                SectionCaption(text: "Ranked apps")
                ForEach(Array(slices.prefix(6).enumerated()), id: \.offset) { index, slice in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(ScreenTimeTile.palette[index % ScreenTimeTile.palette.count])
                            .frame(width: 6, height: 6)
                        Text(ScreenTimeTile.appName(slice.bundleID)).font(.system(size: 10)).lineLimit(1)
                        Spacer()
                        GeometryReader { geo in
                            Capsule().fill(Color.white.opacity(0.15))
                                .overlay(alignment: .leading) {
                                    Capsule()
                                        .fill(ScreenTimeTile.palette[index % ScreenTimeTile.palette.count])
                                        .frame(width: geo.size.width * slice.seconds / total)
                                }
                        }
                        .frame(width: 90, height: 5)
                        Text(ScreenTimeTile.duration(slice.seconds))
                            .font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { tracker.refresh() }
    }
}
