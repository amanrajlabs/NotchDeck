import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private weak var registry: ModuleRegistry?
    private weak var settings: SettingsStore?

    /// Called once at startup so any view can open Settings without plumbing.
    func configure(registry: ModuleRegistry, settings: SettingsStore) {
        self.registry = registry
        self.settings = settings
    }

    func show() {
        guard let registry, let settings else { return }
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
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
    @ObservedObject private var shortcuts = ShortcutSettings.shared

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                Toggle("Show on all displays", isOn: $settings.showOnAllDisplays)
                Toggle("Show notch in screenshots & recordings", isOn: $settings.showInScreenCapture)
                Toggle("Replace system volume/brightness bezel (experimental)", isOn: $settings.hudSuppressSystemBezel)
                HStack {
                    Text("Nudge notch vs menu bar")
                    Slider(value: $settings.notchNudge, in: -8...12, step: 1)
                    Text("\(Int(settings.notchNudge)) pt").monospacedDigit()
                }
                Toggle("Show playback controls when hovering the strip", isOn: $settings.mediaHoverControls)
                Picker("Media visualization", selection: $settings.mediaVisualization) {
                    Text("Bars").tag("bars")
                    Text("Spectrum").tag("spectrum")
                }
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
            Section("Snap Zones") {
                Toggle("Snap windows from the notch", isOn: Binding(
                    get: { settings.snapZonesEnabled },
                    set: { on in
                        if on, !AXWindowSnapper.isTrusted(prompt: true) {
                            // Prompt shown; user must grant in System Settings, then re-toggle.
                            settings.snapZonesEnabled = false
                            return
                        }
                        settings.snapZonesEnabled = on
                        NotchShellControllerShared.instance?.snapControllerSyncEnabled()
                    }
                ))
                ForEach(SnapLayout.allCases, id: \.self) { layout in
                    Toggle(layout.title, isOn: Binding(
                        get: { settings.snapLayouts.contains(layout) },
                        set: { on in
                            if on { settings.snapLayouts.append(layout) }
                            else { settings.snapLayouts.removeAll { $0 == layout } }
                        }
                    ))
                }
            }
            Section("Keyboard Shortcuts") {
                ShortcutRecorderField(title: "Toggle notch", combo: $shortcuts.toggleNotch)
                ShortcutRecorderField(title: "Next module", combo: $shortcuts.nextModule)
                ShortcutRecorderField(title: "Previous module", combo: $shortcuts.prevModule)
                ShortcutRecorderField(title: "Snooze / wake notch", combo: $shortcuts.snooze)
                Stepper("Snooze duration: \(shortcuts.snoozeMinutes) min",
                        value: $shortcuts.snoozeMinutes, in: 5...120, step: 5)
            }
            .onChange(of: shortcuts.toggleNotch) { rebind() }
            .onChange(of: shortcuts.nextModule) { rebind() }
            .onChange(of: shortcuts.prevModule) { rebind() }
            .onChange(of: shortcuts.snooze) { rebind() }
            ForEach(registry.enabledModules, id: \.id) { module in
                module.settingsView()
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 520)
    }

    private func rebind() {
        if let shell = NotchShellControllerShared.instance {
            ShortcutSettings.shared.rebindAll(shell: shell)
        }
    }
}

/// Small "Open Settings" affordance used by module panels that need tokens.
struct OpenSettingsButton: View {
    var title = "Open Settings"

    var body: some View {
        Button(title) { SettingsWindowController.shared.show() }
            .controlSize(.small)
    }
}
