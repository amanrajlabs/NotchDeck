import AppKit

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let registry: ModuleRegistry
    private let settings: SettingsStore

    init(registry: ModuleRegistry, settings: SettingsStore) {
        self.registry = registry
        self.settings = settings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        statusItem.button?.image = NSImage(
            systemSymbolName: "rectangle.topthird.inset.filled",
            accessibilityDescription: "NotchDeck"
        )

        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let snoozeItem = NSMenuItem(title: "Snooze Notch 15 min", action: #selector(snooze), keyEquivalent: "")
        snoozeItem.target = self
        menu.addItem(snoozeItem)
        let wakeItem = NSMenuItem(title: "Wake Notch", action: #selector(wake), keyEquivalent: "")
        wakeItem.target = self
        menu.addItem(wakeItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit NotchDeck", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func snooze() {
        NotchShellControllerShared.instance?.snooze(minutes: 15)
    }

    @objc private func wake() {
        NotchShellControllerShared.instance?.wake()
    }
}
