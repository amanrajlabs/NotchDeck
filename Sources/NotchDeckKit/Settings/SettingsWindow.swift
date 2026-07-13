import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(registry: ModuleRegistry, settings: SettingsStore) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 420),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "NotchDeck Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(
                rootView: SettingsView(registry: registry, settings: settings)
            )
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var registry: ModuleRegistry
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                Toggle("Replace system volume/brightness bezel (experimental)", isOn: $settings.hudSuppressSystemBezel)
            }
            Section("Modules") {
                ForEach(registry.modules, id: \.id) { module in
                    Toggle(isOn: Binding(
                        get: { registry.enabledIDs.contains(module.id) },
                        set: { registry.setEnabled(module.id, $0) }
                    )) {
                        Label(module.name, systemImage: module.icon)
                    }
                }
            }
            ForEach(registry.enabledModules, id: \.id) { module in
                module.settingsView()
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 420)
    }
}
