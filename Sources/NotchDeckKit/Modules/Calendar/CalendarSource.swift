import EventKit
import Foundation

struct EventItem: Identifiable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var meetingURL: URL?
    var color: CGColor?

    var isOngoing: Bool {
        let now = Date()
        return start <= now && now < end
    }
}

/// Pure meeting-link extraction. Tested.
public enum MeetingDetector {
    private static let patterns = [
        #"https?://[\w.-]*zoom\.us/j/[^\s<>"')]+"#,
        #"https?://meet\.google\.com/[a-z0-9-]+"#,
        #"https?://teams\.microsoft\.com/l/meetup-join/[^\s<>"')]+"#,
        #"https?://[\w.-]*webex\.com/[^\s<>"')]+"#,
    ]

    public static func url(in texts: [String?]) -> URL? {
        for text in texts.compactMap({ $0 }) {
            for pattern in patterns {
                if let range = text.range(of: pattern, options: .regularExpression) {
                    return URL(string: String(text[range]))
                }
            }
        }
        return nil
    }
}

@MainActor
final class CalendarSource: ObservableObject {
    enum AccessState { case unknown, granted, denied }

    @Published private(set) var accessState: AccessState = .unknown
    @Published private(set) var events: [EventItem] = []

    private let store = EKEventStore()
    private var changeObserver: NSObjectProtocol?

    func activate() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            accessState = .granted
            startObserving()
            refresh()
        case .notDetermined:
            requestAccess()
        default:
            accessState = .denied
        }
    }

    func deactivate() {
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
        changeObserver = nil
        events = []
    }

    func requestAccess() {
        store.requestFullAccessToEvents { [weak self] granted, _ in
            Task { @MainActor in
                guard let self else { return }
                self.accessState = granted ? .granted : .denied
                if granted {
                    self.startObserving()
                    self.refresh()
                }
            }
        }
    }

    private func startObserving() {
        guard changeObserver == nil else { return }
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { _ in
            Task { @MainActor in CalendarSourceShared.instance?.refresh() }
        }
        CalendarSourceShared.instance = self
    }

    func refresh() {
        guard accessState == .granted else { return }
        let now = Date()
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-3600),
            end: now.addingTimeInterval(24 * 3600),
            calendars: nil
        )
        events = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
            .prefix(10)
            .map { event in
                EventItem(
                    id: event.eventIdentifier ?? UUID().uuidString,
                    title: event.title ?? "Untitled",
                    start: event.startDate,
                    end: event.endDate,
                    meetingURL: MeetingDetector.url(in: [
                        event.url?.absoluteString, event.location, event.notes,
                    ]),
                    color: event.calendar?.cgColor
                )
            }
    }

    var nextEvent: EventItem? {
        events.first { $0.isOngoing || $0.start > Date() }
    }
}

@MainActor
enum CalendarSourceShared {
    weak static var instance: CalendarSource?
}
