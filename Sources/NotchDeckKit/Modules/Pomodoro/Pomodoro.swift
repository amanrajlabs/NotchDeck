import SwiftUI
import UserNotifications

/// Pure Pomodoro state machine with an injectable clock. Tested.
public struct PomodoroEngine: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case work, shortBreak
    }

    public var workMinutes: Int
    public var breakMinutes: Int
    public private(set) var phase: Phase = .work
    public private(set) var completedSessions = 0
    /// Start of the current phase; nil while paused/stopped.
    private var phaseStart: Date?
    /// Time already spent in the phase before the last pause.
    private var banked: TimeInterval = 0

    public init(workMinutes: Int = 25, breakMinutes: Int = 5) {
        self.workMinutes = workMinutes
        self.breakMinutes = breakMinutes
    }

    public var isRunning: Bool { phaseStart != nil }

    public var phaseDuration: TimeInterval {
        TimeInterval((phase == .work ? workMinutes : breakMinutes) * 60)
    }

    public func remaining(at now: Date) -> TimeInterval {
        let elapsed = banked + (phaseStart.map { now.timeIntervalSince($0) } ?? 0)
        return max(0, phaseDuration - elapsed)
    }

    public mutating func start(at now: Date) {
        guard phaseStart == nil else { return }
        phaseStart = now
    }

    public mutating func pause(at now: Date) {
        guard let start = phaseStart else { return }
        banked += now.timeIntervalSince(start)
        phaseStart = nil
    }

    public mutating func reset() {
        phase = .work
        phaseStart = nil
        banked = 0
    }

    /// Rolls into the next phase when the current one has elapsed.
    /// Returns the phase that just *completed*, if any.
    public mutating func advanceIfElapsed(at now: Date) -> Phase? {
        guard isRunning, remaining(at: now) <= 0 else { return nil }
        let finished = phase
        if phase == .work { completedSessions += 1 }
        phase = phase == .work ? .shortBreak : .work
        banked = 0
        phaseStart = now
        return finished
    }
}

@MainActor
final class PomodoroModule: NotchModule, ObservableObject {
    static let moduleID = "pomodoro"
    let id = PomodoroModule.moduleID
    let name = "Pomodoro"
    let icon = "timer"
    let hasPanel = true

    struct Preset: Identifiable {
        let id: String
        let name: String
        let icon: String
        let workMinutes: Int
        let breakMinutes: Int
    }

    static let presets: [Preset] = [
        Preset(id: "work", name: "Work", icon: "briefcase.fill", workMinutes: 25, breakMinutes: 5),
        Preset(id: "short", name: "Short Break", icon: "cup.and.saucer.fill", workMinutes: 5, breakMinutes: 5),
        Preset(id: "long", name: "Long Break", icon: "figure.walk", workMinutes: 15, breakMinutes: 5),
        Preset(id: "quick", name: "Quick Timer", icon: "bolt.fill", workMinutes: 5, breakMinutes: 1),
        Preset(id: "deep", name: "Deep Focus", icon: "brain.head.profile", workMinutes: 50, breakMinutes: 10),
    ]

    @Published private(set) var engine = PomodoroEngine()
    @Published var activePresetID = "work"
    @Published var focusTarget: String?

    var preferredHeight: CGFloat { 190 }

    private var timer: Timer?
    weak var calendarSource: CalendarSource?
    weak var tasks: TasksModule?

    func activate() {}
    func deactivate() {
        timer?.invalidate()
        timer = nil
        engine.reset()
    }

    func panelView() -> AnyView { AnyView(PomodoroPanelView(module: self)) }

    func headerBadge() -> AnyView? {
        AnyView(
            Text("\(engine.completedSessions) sessions today")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        )
    }

    func liveActivityView() -> AnyView? {
        guard engine.isRunning else { return nil }
        return AnyView(PomodoroLivePill(module: self))
    }

    func apply(_ preset: Preset) {
        pause()
        activePresetID = preset.id
        var fresh = PomodoroEngine(workMinutes: preset.workMinutes, breakMinutes: preset.breakMinutes)
        // Carry the session count across preset switches.
        for _ in 0..<engine.completedSessions {
            fresh.start(at: .distantPast)
            _ = fresh.advanceIfElapsed(at: Date())
            fresh.reset()
        }
        engine = PomodoroEngine(workMinutes: preset.workMinutes, breakMinutes: preset.breakMinutes)
    }

    func start() {
        engine.start(at: Date())
        // 1 Hz only while a session runs — user-initiated.
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { PomodoroShared.instance?.tick() }
            }
            PomodoroShared.instance = self
        }
    }

    func pause() {
        engine.pause(at: Date())
        timer?.invalidate()
        timer = nil
    }

    func reset() {
        pause()
        engine.reset()
        focusTarget = nil
    }

    func skip() {
        guard engine.isRunning else { return }
        var advanced = engine
        // Force phase end by pausing and rebuilding at zero remaining.
        advanced.pause(at: Date().addingTimeInterval(engine.remaining(at: Date())))
        advanced.start(at: Date().addingTimeInterval(-engine.phaseDuration))
        _ = advanced.advanceIfElapsed(at: Date())
        engine = advanced
    }

    private func tick() {
        if let finished = engine.advanceIfElapsed(at: Date()) {
            notifyPhaseEnd(finished)
        }
        objectWillChange.send() // countdown labels re-render
    }

    private func notifyPhaseEnd(_ finished: PomodoroEngine.Phase) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = finished == .work ? "Work session done" : "Break over"
        content.body = finished == .work
            ? "Take a \(engine.breakMinutes)-minute break."
            : "Back to work — \(engine.workMinutes) minutes."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: "pomodoro-\(Date().timeIntervalSince1970)",
                content: content, trigger: nil
            )
        )
    }
}

@MainActor
enum PomodoroShared {
    weak static var instance: PomodoroModule?
}

// MARK: - Views

struct PomodoroLivePill: View {
    @ObservedObject var module: PomodoroModule

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: module.engine.phase == .work ? "timer" : "cup.and.saucer.fill")
                .font(.system(size: 11))
                .foregroundStyle(module.engine.phase == .work ? Color.red : Color.green)
            Text(PomodoroPanelView.clock(module.engine.remaining(at: Date())))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

struct PomodoroPanelView: View {
    @ObservedObject var module: PomodoroModule

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            dialColumn.frame(width: 200)
            presetsColumn.frame(width: 160)
            focusColumn.frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var dialColumn: some View {
        let engine = module.engine
        let preset = PomodoroModule.presets.first { $0.id == module.activePresetID }
        let remaining = engine.remaining(at: Date())
        let progress = 1 - remaining / max(engine.phaseDuration, 1)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: preset?.icon ?? "briefcase.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(preset?.name ?? "Work")
                        .font(.system(size: 12, weight: .bold))
                    Text(engine.isRunning ? "In session" : "Ready to focus")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 14) {
                CircleIconButton(icon: "arrow.counterclockwise", size: 24) { module.reset() }
                ZStack {
                    Circle().stroke(Color.white.opacity(0.1), lineWidth: 5)
                    Circle()
                        .trim(from: 0, to: max(0.003, progress))
                        .stroke(
                            engine.phase == .work ? Color.orange : Color.green,
                            style: StrokeStyle(lineWidth: 5, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text(Self.compactClock(remaining))
                            .font(.system(size: 15, weight: .bold).monospacedDigit())
                        Button {
                            engine.isRunning ? module.pause() : module.start()
                        } label: {
                            Image(systemName: engine.isRunning ? "pause.fill" : "play.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 74, height: 74)
                CircleIconButton(icon: "forward.fill", size: 24) { module.skip() }
            }
            HStack(spacing: 5) {
                Image(systemName: "scope")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(module.focusTarget ?? "No focus target")
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                    Text("Select an event, reminder, or task")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var presetsColumn: some View {
        VStack(spacing: 3) {
            ForEach(PomodoroModule.presets) { preset in
                Button {
                    module.apply(preset)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: preset.icon)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .frame(width: 13)
                        Text(preset.name)
                            .font(.system(size: 10, weight: .semibold))
                        Spacer(minLength: 0)
                        Text("\(preset.workMinutes)m")
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(module.activePresetID == preset.id ? Theme.cardHover : Theme.card)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var focusColumn: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: "scope").font(.system(size: 9))
                Text("Focus Target").font(.system(size: 11, weight: .bold))
            }
            Text("Attach this timer to today's schedule.")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(targets, id: \.self) { target in
                        HStack(spacing: 6) {
                            Image(systemName: "list.bullet.circle")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Text(target)
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Button("Select") { module.focusTarget = target }
                                .font(.system(size: 9, weight: .semibold))
                                .buttonStyle(.plain)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.white.opacity(0.9)))
                                .foregroundStyle(.black)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.card))
                    }
                    if targets.isEmpty {
                        Text("Nothing scheduled today")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var targets: [String] {
        var list: [String] = []
        if let events = module.calendarSource?.events.prefix(3) {
            list += events.map(\.title)
        }
        if let tasks = module.tasks?.visibleItems.prefix(3) {
            list += tasks.map(\.title)
        }
        return Array(list.prefix(5))
    }

    static func clock(_ t: TimeInterval) -> String {
        let seconds = Int(t.rounded())
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    static func compactClock(_ t: TimeInterval) -> String {
        let seconds = Int(t.rounded())
        if seconds >= 60 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds)s"
    }
}
