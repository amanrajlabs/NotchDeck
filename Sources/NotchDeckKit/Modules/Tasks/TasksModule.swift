import AppKit
import EventKit
import SwiftUI

@MainActor
final class TasksModule: NotchModule, ObservableObject {
    static let moduleID = "tasks"
    let id = TasksModule.moduleID
    let name = "Todo List"
    let icon = "checklist"
    let hasPanel = true

    enum AccessState { case unknown, granted, denied }
    enum Filter: String, CaseIterable {
        case all = "All"
        case active = "Active"
        case done = "Done"

        var icon: String {
            switch self {
            case .all: "tray.full"
            case .active: "circle"
            case .done: "checkmark.circle"
            }
        }
    }

    struct TaskItem: Identifiable, Equatable {
        let id: String
        var title: String
        var dueDate: Date?
        var isCompleted: Bool
    }

    @Published private(set) var accessState: AccessState = .unknown
    @Published private(set) var items: [TaskItem] = []
    @Published var filter: Filter = .active
    @Published var isAdding = false

    var preferredHeight: CGFloat { 176 }

    private let store = EKEventStore()
    private var changeObserver: NSObjectProtocol?

    var visibleItems: [TaskItem] {
        switch filter {
        case .all: items
        case .active: items.filter { !$0.isCompleted }
        case .done: items.filter(\.isCompleted)
        }
    }

    func count(for filter: Filter) -> Int {
        switch filter {
        case .all: items.count
        case .active: items.filter { !$0.isCompleted }.count
        case .done: items.filter(\.isCompleted).count
        }
    }

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

    func headerBadge() -> AnyView? {
        AnyView(
            Text("\(count(for: .active)) active tasks")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        )
    }

    func headerActions() -> AnyView? {
        AnyView(CircleIconButton(icon: "plus", size: 20) { [weak self] in
            self?.isAdding = true
        })
    }

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
        // Incomplete + recently completed, so the Done filter has content.
        let incomplete = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: nil
        )
        store.fetchReminders(matching: incomplete) { [weak store] reminders in
            let open = (reminders ?? []).prefix(40).map {
                TaskItem(
                    id: $0.calendarItemIdentifier,
                    title: $0.title ?? "Untitled",
                    dueDate: $0.dueDateComponents?.date,
                    isCompleted: false
                )
            }
            guard let store else { return }
            let completedPredicate = store.predicateForCompletedReminders(
                withCompletionDateStarting: Date().addingTimeInterval(-7 * 86_400),
                ending: Date(), calendars: nil
            )
            store.fetchReminders(matching: completedPredicate) { completed in
                let done = (completed ?? []).prefix(15).map {
                    TaskItem(
                        id: $0.calendarItemIdentifier,
                        title: $0.title ?? "Untitled",
                        dueDate: $0.dueDateComponents?.date,
                        isCompleted: true
                    )
                }
                Task { @MainActor in
                    TasksModuleShared.instance?.items = Array(open) + Array(done)
                }
            }
        }
    }

    func complete(_ item: TaskItem) {
        guard let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder else { return }
        reminder.isCompleted = true
        try? store.save(reminder, commit: true)
        if let index = items.firstIndex(of: item) {
            items[index].isCompleted = true
        }
    }

    func delete(_ item: TaskItem) {
        guard let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder else { return }
        try? store.remove(reminder, commit: true)
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

// MARK: - Panel: sidebar + rows

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
            HStack(alignment: .top, spacing: 14) {
                sidebar.frame(width: 118)
                list.frame(maxWidth: .infinity)
            }
            .onAppear { module.refresh() }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 2) {
            ForEach(TasksModule.Filter.allCases, id: \.self) { filter in
                Button {
                    module.filter = filter
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: filter.icon)
                            .font(.system(size: 10))
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(filter.rawValue)
                                .font(.system(size: 11, weight: .semibold))
                            Text("\(module.count(for: filter)) items")
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                        if module.filter == filter {
                            Circle().fill(Color.white).frame(width: 4, height: 4)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(module.filter == filter ? Theme.card : .clear)
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    private var list: some View {
        VStack(spacing: 5) {
            if module.isAdding {
                HStack {
                    TextField("New task…", text: $newTitle)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .onSubmit(submit)
                    Button("Add", action: submit).controlSize(.small)
                    Button {
                        module.isAdding = false
                        newTitle = ""
                    } label: { Image(systemName: "xmark") }
                        .controlSize(.small)
                }
            }
            if module.visibleItems.isEmpty {
                Text(module.filter == .done ? "Nothing completed recently" : "All clear 🎉")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(module.visibleItems) { item in
                            TaskRow(item: item, module: module)
                        }
                    }
                }
            }
        }
    }

    private func submit() {
        module.add(title: newTitle)
        newTitle = ""
        module.isAdding = false
    }
}

struct TaskRow: View {
    let item: TasksModule.TaskItem
    let module: TasksModule
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Text(item.dueDate?.formatted(date: .omitted, time: .shortened) ?? "—")
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 38, alignment: .trailing)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title)
                    .font(.system(size: 11, weight: .semibold))
                    .strikethrough(item.isCompleted)
                    .foregroundStyle(item.isCompleted ? .secondary : .primary)
                    .lineLimit(1)
                if let due = item.dueDate {
                    Text("Due \(due.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 8))
                        .foregroundStyle(due < Date() && !item.isCompleted ? .red : Color.white.opacity(0.35))
                }
            }
            Spacer(minLength: 0)
            if hovering {
                if !item.isCompleted {
                    Button { module.complete(item) } label: {
                        Image(systemName: "circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Complete")
                }
                Button { module.delete(item) } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hovering ? Theme.cardHover : Theme.card)
        )
        .onHover { hovering = $0 }
    }
}
