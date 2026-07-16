import SwiftUI
import UserNotifications

@MainActor
final class AICodingModule: NotchModule, ObservableObject {
    static let moduleID = "ai-coding"
    let id = AICodingModule.moduleID
    let name = "AI Coding"
    let icon = "sparkles"
    let hasPanel = true
    var preferredHeight: CGFloat { 200 }

    @Published private(set) var sessions: [AISession] = []

    private let settings: SettingsStore
    private var watcher: DirectoryWatcher?
    private var notifiedWaiting = Set<String>()

    init(settings: SettingsStore) { self.settings = settings }

    private var activeProviders: [AISessionProvider] {
        var providers: [AISessionProvider] = []
        if settings.isAIProviderEnabled("claude-code") { providers.append(ClaudeCodeProvider()) }
        if settings.isAIProviderEnabled("codex") { providers.append(CodexProvider()) }
        return providers
    }

    func activate() {
        let roots = activeProviders.flatMap { $0.watchRoots() }
            .map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
        let watcher = DirectoryWatcher(paths: roots) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        watcher.start()
        self.watcher = watcher
        AICodingShared.instance = self
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        refresh()
    }

    func deactivate() {
        watcher?.stop()
        watcher = nil
        sessions = []
        notifiedWaiting.removeAll()
    }

    /// Re-arms the FSEvents watcher with the current provider set; only
    /// acts when the module is currently active.
    func reloadProviders() {
        guard watcher != nil else { return }
        deactivate()
        activate()
    }

    /// Re-scan providers off the main thread, publish sorted results on main.
    func refresh() {
        let providers = activeProviders
        Task.detached(priority: .utility) {
            let found = providers.flatMap { $0.scan() }
                .sorted { $0.lastActivity > $1.lastActivity }
            await MainActor.run { AICodingShared.instance?.apply(found) }
        }
    }

    private func apply(_ found: [AISession]) {
        if sessions != found { sessions = found }
        notifyWaiting(found)   // implemented in Task 9
    }

    func focus(_ session: AISession) {
        TerminalFocus.focusFrontmostTerminal()
    }

    private func notifyWaiting(_ found: [AISession]) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let waitingNow = Set(found.filter { $0.status == .waitingApproval }.map(\.id))
        // Clear ids that are no longer waiting so a future wait re-notifies.
        notifiedWaiting.formIntersection(waitingNow)
        for session in found where session.status == .waitingApproval
            && !notifiedWaiting.contains(session.id) {
            notifiedWaiting.insert(session.id)
            let content = UNMutableNotificationContent()
            let provider = session.provider == "codex" ? "Codex" : "Claude Code"
            content.title = "\(provider) waiting for approval"
            content.body = session.projectName
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: "aicoding-\(session.id)", content: content, trigger: nil))
        }
    }

    func panelView() -> AnyView { AnyView(AICodingPanelView(module: self)) }

    func liveActivityView() -> AnyView? {
        guard let waiting = sessions.first(where: { $0.status == .waitingApproval }) else { return nil }
        return AnyView(AIWaitingPill(session: waiting))
    }

    func headerBadge() -> AnyView? {
        let running = sessions.filter { $0.status == .running || $0.status == .waitingApproval }.count
        return AnyView(
            HStack(spacing: 5) {
                Text("(Beta)").font(.system(size: 9)).foregroundStyle(.tertiary)
                if running > 0 {
                    Circle().fill(Color.green).frame(width: 5, height: 5)
                    Text("\(running) active").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.green)
                }
            })
    }
}

@MainActor
enum AICodingShared { weak static var instance: AICodingModule? }
