import AppKit
import Combine
import SwiftUI

/// Owns the notch panel: positions it over the notch, resizes it between the
/// collapsed strip and the expanded dashboard so transparent areas never
/// swallow clicks meant for other apps.
@MainActor
final class NotchShellController {
    private let registry: ModuleRegistry
    private let settings: SettingsStore
    private var panel: NotchPanel?
    private var vm: NotchViewModel?
    private var moduleSet: ModuleSet?
    private var cancellables = Set<AnyCancellable>()
    private var shrinkTask: Task<Void, Never>?
    private var notchRect: CGRect = .zero

    /// Extra width on each side of the notch reserved for live activities.
    static let stripSideMargin: CGFloat = 150

    init(registry: ModuleRegistry, settings: SettingsStore) {
        self.registry = registry
        self.settings = settings
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { NotchShellControllerShared.instance?.repositionPanel() }
        }
        NotchShellControllerShared.instance = self
    }

    func show() {
        guard let screen = Self.targetScreen() else { return }
        notchRect = Self.notchRect(for: screen)

        let vm = NotchViewModel(notchSize: notchRect.size)
        self.vm = vm

        let modules = ModuleSet(settings: settings)
        moduleSet = modules
        modules.dashboard.registry = registry
        registry.register(modules.all)

        let panel = NotchPanel(frame: stripFrame)
        panel.acceptsMouseMovedEvents = true
        let root = NotchRootView(vm: vm, registry: registry, modules: modules)
        let hosting = HoverHostingView(rootView: root)
        hosting.frame = panel.contentLayoutRect
        hosting.autoresizingMask = [.width, .height]
        hosting.onHoverChange = { [weak self] hovering in
            guard let self, let vm = self.vm else { return }
            if hovering && vm.state == .collapsed {
                // Only react near the visible strip, not the whole side margin.
                let x = NSEvent.mouseLocation.x
                let reach = CollapsedStripView.extensionWidth + 10
                guard x > self.notchRect.minX - reach, x < self.notchRect.maxX + reach else { return }
            }
            vm.setHover(hovering)
        }
        panel.contentView = hosting
        self.panel = panel

        vm.$state
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                self.shrinkTask?.cancel()
                switch state {
                case .expanded:
                    self.panel?.setFrame(self.expandedFrame, display: true)
                case .collapsed:
                    // Let the collapse animation finish before shrinking the window.
                    self.shrinkTask = Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(350))
                        guard !Task.isCancelled, let self else { return }
                        self.panel?.setFrame(self.stripFrame, display: true)
                    }
                }
            }
            .store(in: &cancellables)

        panel.orderFrontRegardless()
    }

    func repositionPanel() {
        guard let screen = Self.targetScreen(), let vm, let panel else { return }
        notchRect = Self.notchRect(for: screen)
        vm.notchSize = notchRect.size
        panel.setFrame(vm.state == .expanded ? expandedFrame : stripFrame, display: true)
    }

    private var stripFrame: CGRect {
        NotchGeometry.panelFrame(
            notch: notchRect,
            expandedSize: CGSize(
                width: notchRect.width + Self.stripSideMargin * 2,
                height: notchRect.height
            )
        )
    }

    private var expandedFrame: CGRect {
        NotchGeometry.panelFrame(notch: notchRect, expandedSize: vm?.expandedSize ?? .zero)
    }

    private static func targetScreen() -> NSScreen? {
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
