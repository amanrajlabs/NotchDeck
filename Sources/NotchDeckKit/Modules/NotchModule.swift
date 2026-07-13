import SwiftUI

/// A feature that lives in the notch. Modules hold observers/timers only
/// between activate() and deactivate().
@MainActor
protocol NotchModule: AnyObject {
    var id: String { get }
    var name: String { get }
    /// SF Symbol shown in the expanded tab bar.
    var icon: String { get }
    /// Whether the module contributes a tab to the expanded panel.
    var hasPanel: Bool { get }

    func activate()
    func deactivate()

    func panelView() -> AnyView
    /// Compact view for the collapsed strip; nil when nothing is live.
    func liveActivityView() -> AnyView?
    func settingsView() -> AnyView
}

extension NotchModule {
    func liveActivityView() -> AnyView? { nil }
    func settingsView() -> AnyView { AnyView(EmptyView()) }
}

@MainActor
final class ModuleRegistry: ObservableObject {
    let settings: SettingsStore
    private(set) var modules: [any NotchModule] = []
    @Published private(set) var enabledIDs: Set<String> = []

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func register(_ newModules: [any NotchModule]) {
        modules = newModules
        for module in modules where settings.isModuleEnabled(module.id) {
            module.activate()
            enabledIDs.insert(module.id)
        }
    }

    var enabledModules: [any NotchModule] {
        modules.filter { enabledIDs.contains($0.id) }
    }

    var panelModules: [any NotchModule] {
        enabledModules.filter(\.hasPanel)
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        guard let module = modules.first(where: { $0.id == id }) else { return }
        settings.setModuleEnabled(id, enabled)
        if enabled {
            guard enabledIDs.insert(id).inserted else { return }
            module.activate()
        } else {
            guard enabledIDs.remove(id) != nil else { return }
            module.deactivate()
        }
    }
}
