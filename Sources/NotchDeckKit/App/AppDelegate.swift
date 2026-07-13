import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    override public init() { super.init() }

    private var statusItem: StatusItemController?
    private var shell: NotchShellController?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = SettingsStore()
        let registry = ModuleRegistry(settings: settings)
        let shell = NotchShellController(registry: registry, settings: settings)
        self.shell = shell
        statusItem = StatusItemController(registry: registry, settings: settings)
        shell.show()
    }
}
