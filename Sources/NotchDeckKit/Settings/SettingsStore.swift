import Foundation
import ServiceManagement

@MainActor
final class SettingsStore: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var hudSuppressSystemBezel: Bool {
        didSet { defaults.set(hudSuppressSystemBezel, forKey: "hudSuppressSystemBezel") }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            guard oldValue != launchAtLogin else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // Registration fails when running outside a bundle (swift run);
                // reflect reality in the toggle.
                launchAtLogin = oldValue
            }
        }
    }

    init() {
        hudSuppressSystemBezel = defaults.bool(forKey: "hudSuppressSystemBezel")
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func isModuleEnabled(_ id: String) -> Bool {
        // Modules default to on.
        defaults.object(forKey: "module.\(id).enabled") as? Bool ?? true
    }

    func setModuleEnabled(_ id: String, _ enabled: Bool) {
        defaults.set(enabled, forKey: "module.\(id).enabled")
    }
}
