import AppKit

/// Watches global left-mouse drags and reports whether the user is dragging
/// a window (detected by its AX position tracking the pointer). Global mouse
/// monitors need no permission; the AX reads need Accessibility trust.
@MainActor
final class WindowDragMonitor {
    var onDragChanged: ((CGPoint, Bool) -> Void)?
    var onDragEnded: ((CGPoint) -> Void)?
    private(set) var draggedWindow: AXUIElement?

    private var monitors: [Any] = []
    private var initialWindowOrigin: CGPoint?
    private var dragEventCount = 0
    private var confirmedWindowDrag = false

    func start() {
        guard monitors.isEmpty else { return }
        let dragged = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDragged() }
        }
        let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleUp() }
        }
        monitors = [dragged, up].compactMap { $0 }
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        resetGesture()
    }

    private func handleDragged() {
        dragEventCount += 1
        if dragEventCount == 1 {
            draggedWindow = AXWindowSnapper.windowUnderPointer()
            initialWindowOrigin = draggedWindow.flatMap { AXWindowSnapper.origin(of: $0) }
        } else if !confirmedWindowDrag, dragEventCount >= 3,
                  let window = draggedWindow,
                  let initial = initialWindowOrigin,
                  let current = AXWindowSnapper.origin(of: window),
                  abs(current.x - initial.x) + abs(current.y - initial.y) > 5 {
            confirmedWindowDrag = true
        }
        onDragChanged?(NSEvent.mouseLocation, confirmedWindowDrag)
    }

    private func handleUp() {
        let point = NSEvent.mouseLocation
        let wasWindowDrag = confirmedWindowDrag
        resetGesture()
        if wasWindowDrag { onDragEnded?(point) }
    }

    private func resetGesture() {
        dragEventCount = 0
        confirmedWindowDrag = false
        draggedWindow = nil
        initialWindowOrigin = nil
    }
}
