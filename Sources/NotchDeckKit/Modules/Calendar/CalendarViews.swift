import AppKit
import SwiftUI

@MainActor
final class CalendarModule: NotchModule, ObservableObject {
    static let moduleID = "calendar"
    let id = CalendarModule.moduleID
    let name = "Calendar"
    let icon = "calendar"
    let hasPanel = true
    let source = CalendarSource()
    weak var tasks: TasksModule?

    @Published var displayedMonth = Date()
    @Published var searchText = ""

    var preferredHeight: CGFloat { 186 }

    func activate() { source.activate() }
    func deactivate() { source.deactivate() }

    func panelView() -> AnyView { AnyView(CalendarPanelView(module: self, source: source)) }

    func headerBadge() -> AnyView? {
        AnyView(
            HStack(spacing: 6) {
                Text(displayedMonth.formatted(.dateTime.month(.wide).year()))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                HeaderPill(text: "Today") { [weak self] in
                    self?.displayedMonth = Date()
                }
            }
        )
    }

    func headerActions() -> AnyView? {
        AnyView(
            HStack(spacing: 5) {
                CircleIconButton(icon: "chevron.left", size: 20) { [weak self] in
                    self?.step(by: -1)
                }
                CircleIconButton(icon: "chevron.right", size: 20) { [weak self] in
                    self?.step(by: 1)
                }
            }
        )
    }

    private func step(by months: Int) {
        displayedMonth = Calendar.current.date(
            byAdding: .month, value: months, to: displayedMonth
        ) ?? displayedMonth
    }

    func liveActivityView() -> AnyView? {
        guard let next = source.nextEvent,
              next.isOngoing || next.start.timeIntervalSinceNow < 3600 else { return nil }
        return AnyView(CalendarLivePill(source: source))
    }
}

struct CalendarLivePill: View {
    @ObservedObject var source: CalendarSource

    var body: some View {
        // Periodic timeline keeps the countdown fresh without a controller timer.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let next = source.nextEvent {
                HStack(spacing: 6) {
                    Circle()
                        .fill(next.isOngoing ? Color.red : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(Self.countdownText(for: next, now: context.date))
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    static func countdownText(for event: EventItem, now: Date) -> String {
        if event.isOngoing { return "Now: \(event.title)" }
        let minutes = max(1, Int(event.start.timeIntervalSince(now) / 60))
        if minutes >= 60 { return "\(event.title) in \(minutes / 60)h" }
        return "\(event.title) in \(minutes)m"
    }
}

// MARK: - Panel: month grid + agenda

struct CalendarPanelView: View {
    @ObservedObject var module: CalendarModule
    @ObservedObject var source: CalendarSource

    var body: some View {
        switch source.accessState {
        case .denied:
            VStack(spacing: 10) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("Calendar access is off")
                    .foregroundStyle(.secondary)
                Button("Open Privacy Settings") {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unknown:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .granted:
            HStack(alignment: .top, spacing: 18) {
                MonthGrid(month: module.displayedMonth, events: source.events)
                    .frame(width: 250)
                agenda
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private var visibleEvents: [EventItem] {
        source.events.filter {
            EventSearch.matches(query: module.searchText, in: [$0.title])
        }
    }

    private var overdueTasks: [TasksModule.TaskItem] {
        guard let tasks = module.tasks else { return [] }
        return tasks.items.filter { !$0.isCompleted && ($0.dueDate ?? .distantFuture) < Date() }
    }

    private var agenda: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Search events", text: $module.searchText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(maxWidth: 180)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if visibleEvents.isEmpty {
                        Text(source.events.isEmpty ? "Nothing coming up" : "No matching events")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(visibleEvents) { event in
                            EventRow(event: event)
                        }
                    }

                    let overdue = overdueTasks
                    if !overdue.isEmpty {
                        SectionCaption(text: "Overdue reminders")
                            .padding(.top, 4)
                        ForEach(overdue.prefix(3)) { item in
                            Label(item.title, systemImage: "exclamationmark.circle")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

public struct MonthGrid: View {
    let month: Date
    let events: [EventItem]

    private static let weekdaySymbols = ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"]

    public var body: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let days = Self.gridDays(for: month, calendar: calendar)
        let eventDays = Set(events.map { calendar.startOfDay(for: $0.start) })

        VStack(spacing: 3) {
            HStack(spacing: 0) {
                ForEach(Self.weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(days, id: \.date) { day in
                    let isToday = calendar.startOfDay(for: day.date) == today
                    VStack(spacing: 1) {
                        Text("\(calendar.component(.day, from: day.date))")
                            .font(.system(size: 10, weight: isToday ? .bold : .medium))
                            .foregroundStyle(
                                isToday
                                    ? Color.black
                                    : day.inMonth ? Color.white : Color.white.opacity(0.25)
                            )
                            .frame(width: 19, height: 19)
                            .background(
                                Circle().fill(isToday ? Color.white : .clear)
                            )
                        Circle()
                            .fill(
                                eventDays.contains(calendar.startOfDay(for: day.date))
                                    ? Theme.accent : .clear
                            )
                            .frame(width: 3, height: 3)
                    }
                }
            }
        }
    }

    public struct GridDay: Hashable {
        public let date: Date
        public let inMonth: Bool
    }

    public static func gridDays(for month: Date, calendar: Calendar) -> [GridDay] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: month) else { return [] }
        let firstDay = monthInterval.start
        // Monday-first offset.
        let weekday = calendar.component(.weekday, from: firstDay) // 1 = Sunday
        let leading = (weekday + 5) % 7
        guard let gridStart = calendar.date(byAdding: .day, value: -leading, to: firstDay) else {
            return []
        }
        return (0..<42).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: gridStart) else {
                return nil
            }
            return GridDay(
                date: date,
                inMonth: calendar.isDate(date, equalTo: month, toGranularity: .month)
            )
        }
    }
}

struct EventRow: View {
    let event: EventItem

    var body: some View {
        CardRow {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(event.start.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.accent)
                    Text(event.end.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .frame(width: 42, alignment: .trailing)
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    if event.isOngoing {
                        Text("Now")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.red)
                    }
                }
                Spacer(minLength: 0)
                if let url = event.meetingURL {
                    Button("Join") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                }
                Circle()
                    .fill(event.color.map { Color(cgColor: $0) } ?? Theme.accent)
                    .frame(width: 6, height: 6)
                    .padding(.top, 4)
            }
        }
    }
}
