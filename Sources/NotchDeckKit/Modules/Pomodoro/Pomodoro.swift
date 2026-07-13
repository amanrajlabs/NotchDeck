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

    @Published private(set) var engine = PomodoroEngine()
    private var timer: Timer?

    func activate() {}
    func deactivate() {
        timer?.invalidate()
        timer = nil
        engine.reset()
    }

    func panelView() -> AnyView { AnyView(PomodoroPanelView(module: self)) }

    func liveActivityView() -> AnyView? {
        guard engine.isRunning else { return nil }
        return AnyView(PomodoroLivePill(module: self))
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
        let engine = module.engine
        let remaining = engine.remaining(at: Date())
        let progress = 1 - remaining / max(engine.phaseDuration, 1)

        HStack(spacing: 26) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: max(0.003, progress))
                    .stroke(
                        engine.phase == .work ? Color.red : Color.green,
                        style: StrokeStyle(lineWidth: 7, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    Text(Self.clock(remaining))
                        .font(.system(size: 22, weight: .semibold).monospacedDigit())
                    Text(engine.phase == .work ? "Focus" : "Break")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 120, height: 120)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    Button {
                        engine.isRunning ? module.pause() : module.start()
                    } label: {
                        Image(systemName: engine.isRunning ? "pause.fill" : "play.fill")
                            .font(.system(size: 20))
                    }
                    Button { module.reset() } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 16))
                    }
                }
                .buttonStyle(.plain)
                Text("Sessions today: \(engine.completedSessions)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("\(engine.workMinutes) min focus · \(engine.breakMinutes) min break")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func clock(_ t: TimeInterval) -> String {
        let seconds = Int(t.rounded())
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
