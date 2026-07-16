import AppKit
import SQLite3
import SwiftUI

public struct NotificationItem: Identifiable, Equatable, Sendable {
    public var id: String
    public var appBundleID: String
    public var title: String
    public var subtitle: String
    public var body: String
    public var date: Date

    public init(id: String, appBundleID: String, title: String, subtitle: String, body: String, date: Date) {
        self.id = id
        self.appBundleID = appBundleID
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.date = date
    }
}

/// Decodes one usernoted `record.data` blob (a binary plist whose `req`
/// dictionary carries titl/subt/body). Pure and tested.
public enum NotificationRowParser {
    public static func parse(data: Data, appID: String, uuid: String, deliveredCocoa: Double) -> NotificationItem? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let root = plist as? [String: Any],
              let request = root["req"] as? [String: Any] else { return nil }
        let title = request["titl"] as? String ?? ""
        let subtitle = request["subt"] as? String ?? ""
        let body = request["body"] as? String ?? ""
        guard !(title.isEmpty && body.isEmpty) else { return nil }
        return NotificationItem(
            id: uuid,
            appBundleID: appID,
            title: title,
            subtitle: subtitle,
            body: body,
            date: Date(timeIntervalSinceReferenceDate: deliveredCocoa)
        )
    }
}

/// Read-only access to Notification Center's SQLite store. Requires Full
/// Disk Access; callers get `.needsFullDiskAccess` otherwise.
enum NotificationsDB {
    enum ReadResult {
        case ok([NotificationItem])
        case needsFullDiskAccess
        /// Opened fine but the schema differs (macOS change).
        case unsupportedSchema
    }

    static var dbPath: String {
        NSHomeDirectory() + "/Library/Group Containers/group.com.apple.usernoted/db2/db"
    }

    static func recent(limit: Int = 30) -> ReadResult {
        var db: OpaquePointer?
        // WAL databases support concurrent readers; a plain read-only open
        // plus a busy timeout is safer than immutable=1 against a live db.
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else {
            sqlite3_close(db)
            return .needsFullDiskAccess
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        let sql = """
        SELECT app.identifier, hex(record.uuid), record.data, record.delivered_date
        FROM record JOIN app ON record.app_id = app.app_id
        WHERE record.delivered_date IS NOT NULL
        ORDER BY record.delivered_date DESC LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return .unsupportedSchema
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))

        var items: [NotificationItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let appC = sqlite3_column_text(statement, 0),
                  let uuidC = sqlite3_column_text(statement, 1),
                  let blob = sqlite3_column_blob(statement, 2) else { continue }
            let length = Int(sqlite3_column_bytes(statement, 2))
            let data = Data(bytes: blob, count: length)
            let delivered = sqlite3_column_double(statement, 3)
            if let item = NotificationRowParser.parse(
                data: data,
                appID: String(cString: appC),
                uuid: String(cString: uuidC),
                deliveredCocoa: delivered
            ) {
                items.append(item)
            }
        }
        return .ok(items)
    }
}

// MARK: - Module

@MainActor
final class NotificationsModule: NotchModule, ObservableObject {
    static let moduleID = "notifications"
    let id = NotificationsModule.moduleID
    let name = "Notifications"
    let icon = "bell.fill"
    let hasPanel = true
    var preferredHeight: CGFloat { 180 }

    @Published private(set) var items: [NotificationItem] = []
    @Published private(set) var needsAccess = false
    @Published private(set) var unsupported = false
    private var timer: Timer?
    private var dismissedOrder: [String] = []   // dismissal order, oldest→newest
    private var dismissedIDs: Set<String> = []  // O(1) membership for the refresh filter

    func activate() {
        loadDismissed()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { NotificationsModuleShared.instance?.refresh() }
        }
        NotificationsModuleShared.instance = self
    }

    private func loadDismissed() {
        let stored = UserDefaults.standard.stringArray(forKey: "notifications.dismissed") ?? []
        dismissedOrder = Array(stored.suffix(500))
        dismissedIDs = Set(dismissedOrder)
    }

    private func saveDismissed() {
        if dismissedOrder.count > 500 {
            dismissedOrder = Array(dismissedOrder.suffix(500))
            dismissedIDs = Set(dismissedOrder)
        }
        UserDefaults.standard.set(dismissedOrder, forKey: "notifications.dismissed")
    }

    func dismiss(_ id: String) {
        if dismissedIDs.insert(id).inserted {
            dismissedOrder.append(id)
        }
        saveDismissed()
        items.removeAll { $0.id == id }
    }

    func dismissAll() {
        for item in items where dismissedIDs.insert(item.id).inserted {
            dismissedOrder.append(item.id)
        }
        saveDismissed()
        items = []
    }

    func deactivate() {
        timer?.invalidate()
        timer = nil
        items = []
    }

    func panelView() -> AnyView { AnyView(NotificationsPanelView(module: self)) }

    func headerBadge() -> AnyView? {
        AnyView(
            Text("\(items.count) recent")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        )
    }

    func headerActions() -> AnyView? {
        AnyView(
            HeaderPill(text: "Clear all", icon: "xmark") { [weak self] in
                self?.dismissAll()
            }
        )
    }

    func refresh() {
        // The query runs in ~ms, but keep it off the main actor anyway.
        Task.detached(priority: .utility) {
            let result = NotificationsDB.recent()
            await MainActor.run {
                guard let self = NotificationsModuleShared.instance else { return }
                switch result {
                case .ok(let items):
                    if self.needsAccess { self.needsAccess = false }
                    if self.unsupported { self.unsupported = false }
                    let items = items.filter { !self.dismissedIDs.contains($0.id) }
                    if self.items != items { self.items = items }
                case .needsFullDiskAccess:
                    if !self.needsAccess { self.needsAccess = true }
                case .unsupportedSchema:
                    if !self.unsupported { self.unsupported = true }
                }
            }
        }
    }

    func open(_ item: NotificationItem) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.appBundleID)
        else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Pill for the collapsed strip's rotating trailing slot: app name +
    /// count of items delivered in the last 15 minutes. Nil when none.
    func glanceView() -> AnyView? {
        let recent = items.filter { $0.date.timeIntervalSinceNow > -900 }
        guard let newest = recent.first else { return nil }
        let appName = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: newest.appBundleID)
            .map { FileManager.default.displayName(atPath: $0.path) }
            ?? newest.appBundleID.components(separatedBy: ".").last?.capitalized
            ?? "New"
        return AnyView(
            HStack(spacing: 6) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.accent)
                Text(recent.count == 1 ? appName : "\(recent.count) new")
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .trailing)
        )
    }
}

@MainActor
enum NotificationsModuleShared {
    weak static var instance: NotificationsModule?
}

struct NotificationsPanelView: View {
    @ObservedObject var module: NotificationsModule

    var body: some View {
        Group {
            if module.needsAccess {
                VStack(spacing: 8) {
                    Image(systemName: "bell.slash.fill")
                        .font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("Reading notifications needs Full Disk Access")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Enable NotchDeck there, then relaunch the app")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                    Button("Open Privacy Settings") {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if module.unsupported {
                VStack(spacing: 8) {
                    Image(systemName: "bell.slash.fill")
                        .font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("Notification store format isn't supported on this macOS version")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if module.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("No recent notifications").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 7) {
                        ForEach(module.items) { item in
                            NotificationRow(
                                item: item,
                                openAction: { module.open(item) },
                                dismissAction: { module.dismiss(item.id) }
                            )
                        }
                    }
                }
            }
        }
        .onAppear { module.refresh() }
    }
}

struct NotificationRow: View {
    let item: NotificationItem
    let openAction: () -> Void
    let dismissAction: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: openAction) {
                HStack(alignment: .top, spacing: 8) {
                    appIcon
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Spacer()
                            Text(item.date, style: .relative)
                                .font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                        if !item.subtitle.isEmpty {
                            Text(item.subtitle).font(.system(size: 11)).lineLimit(1)
                        }
                        Text(item.body)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .buttonStyle(.plain)
            if hovering {
                Button(action: dismissAction) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
        .onHover { hovering = $0 }
    }

    private var appIcon: some View {
        Group {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.appBundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().frame(width: 22, height: 22)
            } else {
                Image(systemName: "app.badge.fill")
                    .frame(width: 22, height: 22)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
