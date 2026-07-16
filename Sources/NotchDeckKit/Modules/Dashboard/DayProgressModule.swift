import SwiftUI

/// Full-panel day timeline: calendar events plotted between the configured
/// start hour and bedtime, with a marker for the workday end.
@MainActor
final class DayProgressModule: NotchModule, ObservableObject {
    static let moduleID = "dayprogress"
    let id = DayProgressModule.moduleID
    let name = "Day Progress"
    let icon = "chart.bar.fill"
    let hasPanel = true
    var preferredHeight: CGFloat { 150 }

    weak var calendarSource: CalendarSource?
    weak var tasks: TasksModule?

    func activate() {}
    func deactivate() {}

    func panelView() -> AnyView { AnyView(DayProgressPanelView(module: self)) }

    func settingsView() -> AnyView { AnyView(DayProgressSettingsView()) }
}

struct DayProgressSettingsView: View {
    @AppStorage("dayprogress.bedtime") private var bedtimeHour = 23

    var body: some View {
        Section("Day Progress") {
            Stepper("Bedtime: \(bedtimeHour % 24):00", value: $bedtimeHour, in: 19...27)
        }
    }
}

struct DayProgressPanelView: View {
    @ObservedObject var module: DayProgressModule
    @AppStorage("dayprogress.start") private var startHour = 9
    @AppStorage("dayprogress.end") private var endHour = 18
    @AppStorage("dayprogress.bedtime") private var bedtimeHour = 23

    var body: some View {
        // 60 s UI-only tick, alive only while this panel is on-screen — drives
        // the "now" dot and elapsed percentage, no polling of module state.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let calendar = Calendar.current
            let dayStart = calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: context.date)
                ?? context.date
            // endHour/bedtimeHour may exceed 24 (past-midnight bedtime); model
            // both as offsets from dayStart rather than re-anchoring per day.
            let dayEnd = dayStart.addingTimeInterval(Double(endHour - startHour) * 3_600)
            let bedtime = dayStart.addingTimeInterval(Double(bedtimeHour - startHour) * 3_600)
            let events = (module.calendarSource?.events ?? []).map { (start: $0.start, end: $0.end) }
            let blocks = DayTimeline.blocks(events: events, dayStart: dayStart, dayEnd: bedtime)
            let nowFraction = DayTimeline.fraction(of: context.date, dayStart: dayStart, dayEnd: bedtime)
            let workEndFraction = DayTimeline.fraction(of: dayEnd, dayStart: dayStart, dayEnd: bedtime)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if let nowFraction {
                        Text("\(Int(nowFraction * 100))% of your day")
                            .font(.system(size: 14, weight: .bold))
                    } else {
                        Text("Outside your day")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(startHour):00 → bed \(bedtimeHour % 24):00")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.1)).frame(height: 10)
                        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                            Capsule()
                                .fill(Theme.accent.opacity(0.6))
                                .frame(
                                    width: max(4, (block.endFraction - block.startFraction) * geo.size.width),
                                    height: 10
                                )
                                .offset(x: block.startFraction * geo.size.width)
                        }
                        if let workEndFraction {
                            Rectangle().fill(Color.orange).frame(width: 2, height: 16)
                                .offset(x: workEndFraction * geo.size.width)
                        }
                        Rectangle().fill(Color.purple).frame(width: 2, height: 16)
                            .offset(x: geo.size.width - 2) // bedtime = end of bar
                        if let nowFraction {
                            Circle().fill(Color.white).frame(width: 8, height: 8)
                                .offset(x: nowFraction * geo.size.width - 4)
                        }
                    }
                }
                .frame(height: 18)

                if let tasks = module.tasks {
                    let open = tasks.items.filter { !$0.isCompleted }.count
                    Text("\(open) open task\(open == 1 ? "" : "s") · \(module.calendarSource?.events.count ?? 0) events today")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        }
    }
}
