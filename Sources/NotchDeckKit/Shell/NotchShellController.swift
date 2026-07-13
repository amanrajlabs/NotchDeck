import AppKit
import Combine
import SwiftUI

/// Owns the notch panels (one per displayed screen): positions them over the
/// notch (or a simulated one), and resizes them between the collapsed strip
/// and the expanded dashboard so transparent areas never swallow clicks
/// meant for other apps.
@MainActor
final class NotchShellController {
    private struct ScreenPanel {
        let panel: NotchPanel
        let vm: NotchViewModel
        var notchRect: CGRect
        var cancellable: AnyCancellable?
        var shrinkTask: Task<Void, Never>?
        var keyObserver: NSObjectProtocol?
    }

    private let registry: ModuleRegistry
    private let settings: SettingsStore
    private var moduleSet: ModuleSet?
    private var screenPanels: [ScreenPanel] = []

    /// Extra width on each side of the notch reserved for live activities.
    static let stripSideMargin: CGFloat = 150

    init(registry: ModuleRegistry, settings: SettingsStore) {
        self.registry = registry
        self.settings = settings
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { NotchShellControllerShared.instance?.rebuildPanels() }
        }
        NotchShellControllerShared.instance = self
        settings.onDisplayConfigChange = { [weak self] in self?.rebuildPanels() }
    }

    func show() {
        let modules = ModuleSet(settings: settings)
        moduleSet = modules
        modules.dashboard.registry = registry
        modules.dashboard.calendarSource = modules.calendar.source
        modules.dashboard.pomodoro = modules.pomodoro
        modules.pomodoro.calendarSource = modules.calendar.source
        modules.pomodoro.tasks = modules.tasks
        registry.register(modules.all)
        rebuildPanels()
    }

    func rebuildPanels() {
        for entry in screenPanels {
            entry.shrinkTask?.cancel()
            entry.cancellable?.cancel()
            if let keyObserver = entry.keyObserver {
                NotificationCenter.default.removeObserver(keyObserver)
            }
            entry.panel.orderOut(nil)
            entry.panel.contentView = nil
        }
        screenPanels = []

        guard let modules = moduleSet else { return }
        let screens: [NSScreen]
        if settings.showOnAllDisplays {
            screens = NSScreen.screens
        } else {
            screens = Self.primaryScreen().map { [$0] } ?? []
        }
        for screen in screens {
            addPanel(for: screen, modules: modules)
        }
    }

    private func addPanel(for screen: NSScreen, modules: ModuleSet) {
        let notchRect = Self.notchRect(for: screen)
        let vm = NotchViewModel(notchSize: notchRect.size)

        let panel = NotchPanel(frame: Self.stripFrame(notch: notchRect))
        panel.acceptsMouseMovedEvents = true
        let root = NotchRootView(vm: vm, registry: registry, modules: modules)
        let hosting = HoverHostingView(rootView: root)
        hosting.frame = panel.contentLayoutRect
        hosting.autoresizingMask = [.width, .height]
        hosting.onHoverChange = { [weak vm, weak panel] hovering in
            guard let vm else { return }
            if hovering && vm.state == .collapsed {
                // Only react near the visible strip, not the whole side margin.
                let x = NSEvent.mouseLocation.x
                let reach = CollapsedStripView.extensionWidth + 10
                guard x > notchRect.minX - reach, x < notchRect.maxX + reach else { return }
            }
            // While the panel is key the user is typing or mid-dialog —
            // don't yank the panel away under them.
            if !hovering, panel?.isKeyWindow == true { return }
            vm.setHover(hovering)
        }
        panel.contentView = hosting

        // Collapse once interaction truly ends: key resigned + pointer gone.
        let keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak vm, weak panel] _ in
            MainActor.assumeIsolated {
                guard let vm, let panel, vm.state == .expanded else { return }
                if !panel.frame.contains(NSEvent.mouseLocation) {
                    vm.collapse()
                }
            }
        }

        var entry = ScreenPanel(panel: panel, vm: vm, notchRect: notchRect)
        entry.keyObserver = keyObserver
        entry.cancellable = vm.$state
            .removeDuplicates()
            .sink { [weak self, weak panel, weak vm] state in
                guard let self, let panel, let vm else { return }
                guard let index = self.screenPanels.firstIndex(where: { $0.panel === panel })
                else { return }
                self.screenPanels[index].shrinkTask?.cancel()
                let notch = self.screenPanels[index].notchRect
                switch state {
                case .expanded:
                    panel.setFrame(
                        NotchGeometry.panelFrame(notch: notch, expandedSize: vm.expandedSize),
                        display: true
                    )
                case .collapsed:
                    // Let the collapse animation finish before shrinking.
                    self.screenPanels[index].shrinkTask = Task { [weak panel] in
                        try? await Task.sleep(for: .milliseconds(350))
                        guard !Task.isCancelled, let panel else { return }
                        panel.setFrame(Self.stripFrame(notch: notch), display: true)
                    }
                }
            }
        screenPanels.append(entry)
        panel.orderFrontRegardless()
    }

    private static func stripFrame(notch: CGRect) -> CGRect {
        NotchGeometry.panelFrame(
            notch: notch,
            expandedSize: CGSize(
                width: notch.width + stripSideMargin * 2,
                height: notch.height
            )
        )
    }

    private static func primaryScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    private static func notchRect(for screen: NSScreen) -> CGRect {
        let hasNotch = screen.safeAreaInsets.top > 0
        return NotchGeometry.notchRect(
            screenFrame: screen.frame,
            safeTopInset: screen.safeAreaInsets.top,
            auxTopLeftWidth: hasNotch ? screen.auxiliaryTopLeftArea?.width : nil,
            auxTopRightWidth: hasNotch ? screen.auxiliaryTopRightArea?.width : nil
        )
    }
}

/// Weak holder so the screen-change observer block stays Sendable-clean.
@MainActor
enum NotchShellControllerShared {
    weak static var instance: NotchShellController?
}
