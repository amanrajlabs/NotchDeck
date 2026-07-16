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

    // Presentation hooks for the expanded chrome.
    /// Panel content height (excluding header) in points.
    var preferredHeight: CGFloat { get }
    /// Small view rendered next to the title (source pill, counts, …).
    func headerBadge() -> AnyView?
    /// Module-specific buttons rendered right of the notch in the header.
    func headerActions() -> AnyView?
}

extension NotchModule {
    func liveActivityView() -> AnyView? { nil }
    func settingsView() -> AnyView { AnyView(EmptyView()) }
    var preferredHeight: CGFloat { 170 }
    func headerBadge() -> AnyView? { nil }
    func headerActions() -> AnyView? { nil }
}

@MainActor
final class ModuleRegistry: ObservableObject {
    let settings: SettingsStore
    private(set) var modules: [any NotchModule] = []
    @Published private(set) var enabledIDs: Set<String> = []
    @Published private(set) var orderVersion = 0

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func register(_ newModules: [any NotchModule]) {
        let saved = UserDefaults.standard.stringArray(forKey: "module.order") ?? []
        let orderedIDs = ModuleOrder.apply(order: saved, to: newModules.map(\.id))
        modules = orderedIDs.compactMap { id in newModules.first { $0.id == id } }
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

    /// Swaps the module at `id` with its neighbor `delta` positions away and
    /// persists the new order so it survives relaunch.
    func moveModule(_ id: String, by delta: Int) {
        guard let index = modules.firstIndex(where: { $0.id == id }) else { return }
        let target = index + delta
        guard modules.indices.contains(target) else { return }
        modules.swapAt(index, target)
        UserDefaults.standard.set(modules.map(\.id), forKey: "module.order")
        orderVersion += 1
    }
}

/// Pure ordering helper: applies a saved id order to a list of ids, with
/// unknown/missing ids kept in their relative position at the end.
public enum ModuleOrder {
    public static func apply(order: [String], to ids: [String]) -> [String] {
        let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return ids.enumerated().sorted {
            let a = position[$0.element] ?? order.count + $0.offset
            let b = position[$1.element] ?? order.count + $1.offset
            return a < b
        }.map(\.element)
    }
}
