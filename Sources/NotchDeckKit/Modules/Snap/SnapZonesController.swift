import AppKit

/// Orchestrates snap zones: drag monitor -> show tiles in the notch panel of
/// the screen being dragged on -> snap on release.
@MainActor
final class SnapZonesController {
    private let settings: SettingsStore
    private let monitor = WindowDragMonitor()
    /// Provided by the shell: find the panel/vm for the screen under a point.
    var target: ((CGPoint) -> (vm: NotchViewModel, notch: CGRect, screen: NSScreen)?)?

    private var activeVM: NotchViewModel?
    private var activeStrip: CGRect?
    private var activeScreen: NSScreen?
    /// Snapshot of the window at gesture time -- the monitor clears its copy on mouse-up.
    private var pendingWindow: AXUIElement?

    init(settings: SettingsStore) {
        self.settings = settings
        monitor.onDragChanged = { [weak self] point, isWindowDrag in
            self?.dragChanged(point, isWindowDrag: isWindowDrag)
        }
        monitor.onDragEnded = { [weak self] point in self?.dragEnded(point) }
    }

    func syncEnabled() {
        if settings.snapZonesEnabled, AXWindowSnapper.isTrusted(prompt: false) {
            monitor.start()
        } else {
            monitor.stop()
            hide()
        }
    }

    private func dragChanged(_ point: CGPoint, isWindowDrag: Bool) {
        guard isWindowDrag, let (vm, notch, screen) = target?(point) else {
            hide()
            return
        }
        let nearTop = point.y > screen.visibleFrame.maxY - 40
        guard nearTop else {
            hide()
            return
        }
        pendingWindow = monitor.draggedWindow
        let layouts = settings.snapLayouts
        let strip = SnapZoneMath.stripFrame(notch: notch, tileCount: layouts.count)
        if vm.snapZones == nil { vm.snapZones = layouts }
        vm.snapHighlight = SnapZoneMath.tileIndex(at: point, strip: strip, count: layouts.count)
        activeVM = vm
        activeStrip = strip
        activeScreen = screen
    }

    private func dragEnded(_ point: CGPoint) {
        defer { hide() }
        guard let strip = activeStrip, let screen = activeScreen,
              let window = pendingWindow,
              let index = SnapZoneMath.tileIndex(at: point, strip: strip, count: settings.snapLayouts.count)
        else { return }
        let layout = settings.snapLayouts[index]
        AXWindowSnapper.setFrame(layout.frame(in: screen.visibleFrame), of: window)
    }

    private func hide() {
        activeVM?.snapZones = nil
        activeVM?.snapHighlight = nil
        activeVM = nil
        activeStrip = nil
        activeScreen = nil
        pendingWindow = nil
    }
}
