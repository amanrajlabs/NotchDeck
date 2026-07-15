import Foundation
import ServiceManagement

@MainActor
final class SettingsStore: ObservableObject {
    private let defaults = UserDefaults.standard

    /// Called when panel/display configuration settings change.
    var onDisplayConfigChange: (() -> Void)?

    @Published var hudSuppressSystemBezel: Bool {
        didSet { defaults.set(hudSuppressSystemBezel, forKey: "hudSuppressSystemBezel") }
    }

    @Published var showOnAllDisplays: Bool {
        didSet {
            defaults.set(showOnAllDisplays, forKey: "showOnAllDisplays")
            onDisplayConfigChange?()
        }
    }

    @Published var showInScreenCapture: Bool {
        didSet {
            defaults.set(showInScreenCapture, forKey: "showInScreenCapture")
            onDisplayConfigChange?()
        }
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
        showOnAllDisplays = defaults.bool(forKey: "showOnAllDisplays")
        showInScreenCapture = defaults.object(forKey: "showInScreenCapture") as? Bool ?? true
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
