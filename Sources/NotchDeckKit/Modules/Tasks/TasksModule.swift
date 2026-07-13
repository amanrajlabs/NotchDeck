import AppKit
import EventKit
import SwiftUI

@MainActor
final class TasksModule: NotchModule, ObservableObject {
    static let moduleID = "tasks"
    let id = TasksModule.moduleID
    let name = "Tasks"
    let icon = "checklist"
    let hasPanel = true

    enum AccessState { case unknown, granted, denied }

    struct TaskItem: Identifiable {
        let id: String
        var title: String
        var dueDate: Date?
    }

    @Published private(set) var accessState: AccessState = .unknown
    @Published private(set) var items: [TaskItem] = []

    private let store = EKEventStore()
    private var changeObserver: NSObjectProtocol?

    func activate() {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:
            accessState = .granted
            startObserving()
            refresh()
        case .notDetermined:
            store.requestFullAccessToReminders { [weak self] granted, _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.accessState = granted ? .granted : .denied
                    if granted {
                        self.startObserving()
                        self.refresh()
                    }
                }
            }
        default:
            accessState = .denied
        }
    }

    func deactivate() {
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
        changeObserver = nil
        items = []
    }

    func panelView() -> AnyView { AnyView(TasksPanelView(module: self)) }

    private func startObserving() {
        guard changeObserver == nil else { return }
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { _ in
            Task { @MainActor in TasksModuleShared.instance?.refresh() }
        }
        TasksModuleShared.instance = self
    }

    func refresh() {
        guard accessState == .granted else { return }
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: nil
        )
        store.fetchReminders(matching: predicate) { reminders in
            let mapped = (reminders ?? []).prefix(30).map { reminder in
                TaskItem(
                    id: reminder.calendarItemIdentifier,
                    title: reminder.title ?? "Untitled",
                    dueDate: reminder.dueDateComponents?.date
                )
            }
            Task { @MainActor in
                TasksModuleShared.instance?.items = Array(mapped)
            }
        }
    }

    func complete(_ item: TaskItem) {
        guard let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder else { return }
        reminder.isCompleted = true
        try? store.save(reminder, commit: true)
        items.removeAll { $0.id == item.id }
    }

    func add(title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let reminder = EKReminder(eventStore: store)
        reminder.title = trimmed
        reminder.calendar = store.defaultCalendarForNewReminders()
        try? store.save(reminder, commit: true)
        refresh()
    }
}

@MainActor
enum TasksModuleShared {
    weak static var instance: TasksModule?
}

struct TasksPanelView: View {
    @ObservedObject var module: TasksModule
    @State private var newTitle = ""

    var body: some View {
        switch module.accessState {
        case .denied:
            VStack(spacing: 10) {
                Image(systemName: "checklist")
                    .font(.system(size: 28)).foregroundStyle(.secondary)
                Text("Reminders access is off").foregroundStyle(.secondary)
                Button("Open Privacy Settings") {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unknown:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .granted:
            VStack(spacing: 8) {
                HStack {
                    TextField("Add a task…", text: $newTitle)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .onSubmit(submit)
                    Button("Add", action: submit).controlSize(.small)
                }
                if module.items.isEmpty {
                    Text("All clear 🎉").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(module.items) { item in
                                HStack(spacing: 8) {
                                    Button { module.complete(item) } label: {
                                        Image(systemName: "circle")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    Text(item.title).font(.system(size: 12)).lineLimit(1)
                                    Spacer()
                                    if let due = item.dueDate {
                                        Text(due, style: .date)
                                            .font(.system(size: 10))
                                            .foregroundStyle(due < Date() ? .red : .secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .onAppear { module.refresh() }
        }
    }

    private func submit() {
        module.add(title: newTitle)
        newTitle = ""
    }
}
