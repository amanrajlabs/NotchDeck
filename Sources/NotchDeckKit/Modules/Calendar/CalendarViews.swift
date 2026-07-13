import AppKit
import SwiftUI

@MainActor
final class CalendarModule: NotchModule {
    static let moduleID = "calendar"
    let id = CalendarModule.moduleID
    let name = "Calendar"
    let icon = "calendar"
    let hasPanel = true
    let source = CalendarSource()

    func activate() { source.activate() }
    func deactivate() { source.deactivate() }

    func panelView() -> AnyView { AnyView(CalendarPanelView(source: source)) }

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

struct CalendarPanelView: View {
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
            if source.events.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "calendar")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("Nothing coming up")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(source.events) { event in
                            EventRow(event: event)
                        }
                    }
                }
            }
        }
    }
}

struct EventRow: View {
    let event: EventItem

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(event.color.map { Color(cgColor: $0) } ?? .accentColor)
                .frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text("\(Self.timeFormatter.string(from: event.start)) – \(Self.timeFormatter.string(from: event.end))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if event.isOngoing {
                Text("Now")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.red)
            }
            if let url = event.meetingURL {
                Button("Join") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 4)
    }
}
