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

    @Published var notchNudge: Double {
        didSet {
            defaults.set(notchNudge, forKey: "notchNudge")
            onDisplayConfigChange?()
        }
    }

    @Published var snapZonesEnabled: Bool {
        didSet { defaults.set(snapZonesEnabled, forKey: "snapZonesEnabled") }
    }

    @Published var snapLayouts: [SnapLayout] {
        didSet {
            if let data = try? JSONEncoder().encode(snapLayouts) {
                defaults.set(data, forKey: "snapLayouts")
            }
        }
    }

    @Published var mediaHoverControls: Bool {
        didSet { defaults.set(mediaHoverControls, forKey: "mediaHoverControls") }
    }

    @Published var mediaVisualization: String {
        didSet { defaults.set(mediaVisualization, forKey: "mediaVisualization") }
    }

    /// Module shown when a fresh panel expands; nil falls back to the first
    /// enabled panel module.
    @Published var defaultModuleID: String? {
        didSet { defaults.set(defaultModuleID, forKey: "module.default") }
    }

    init() {
        // Migrate persisted module id "claude" → "ai-coding" before reading defaults
        let orderKey = "module.order"
        let order = defaults.stringArray(forKey: orderKey) ?? []
        let currentDefault = defaults.string(forKey: "module.default")
        let result = AICodingMigration.migrate(order: order, defaultModule: currentDefault)
        if result.order != order { defaults.set(result.order, forKey: orderKey) }
        if result.defaultModule != currentDefault {
            defaults.set(result.defaultModule, forKey: "module.default")
        }
        // Per-module enabled flag is stored as "module.<id>.enabled"
        let oldEnabledKey = "module.claude.enabled"
        if defaults.object(forKey: oldEnabledKey) != nil {
            let value = defaults.bool(forKey: oldEnabledKey)
            defaults.set(value, forKey: "module.ai-coding.enabled")
            defaults.removeObject(forKey: oldEnabledKey)
        }
        hudSuppressSystemBezel = defaults.bool(forKey: "hudSuppressSystemBezel")
        showOnAllDisplays = defaults.bool(forKey: "showOnAllDisplays")
        showInScreenCapture = defaults.object(forKey: "showInScreenCapture") as? Bool ?? true
        launchAtLogin = SMAppService.mainApp.status == .enabled
        notchNudge = defaults.double(forKey: "notchNudge")
        snapZonesEnabled = defaults.bool(forKey: "snapZonesEnabled")
        if let data = defaults.data(forKey: "snapLayouts"),
           let decoded = try? JSONDecoder().decode([SnapLayout].self, from: data) {
            snapLayouts = decoded
        } else {
            snapLayouts = [.leftHalf, .maximize, .rightHalf, .leftThird, .rightThird]
        }
        mediaHoverControls = defaults.object(forKey: "mediaHoverControls") as? Bool ?? true
        mediaVisualization = defaults.string(forKey: "mediaVisualization") ?? "bars"
        defaultModuleID = defaults.string(forKey: "module.default")
    }

    func isModuleEnabled(_ id: String) -> Bool {
        // Modules default to on.
        defaults.object(forKey: "module.\(id).enabled") as? Bool ?? true
    }

    func setModuleEnabled(_ id: String, _ enabled: Bool) {
        defaults.set(enabled, forKey: "module.\(id).enabled")
    }

    /// Stub for Task 7; Task 9 replaces this with a real per-provider toggle.
    func isAIProviderEnabled(_ id: String) -> Bool { true }
}
