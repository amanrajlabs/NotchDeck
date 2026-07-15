import AppKit
import ApplicationServices

/// Thin wrapper over the Accessibility API for reading and moving other
/// apps' windows. Requires the user to trust NotchDeck in
/// System Settings → Privacy & Security → Accessibility.
enum AXWindowSnapper {
    static func isTrusted(prompt: Bool) -> Bool {
        // kAXTrustedCheckOptionPrompt is a non-Sendable global var under Swift 6;
        // its documented CFString value is used directly to stay concurrency-safe.
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private static var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    /// The AX window element under the current mouse location, if any.
    static func windowUnderPointer() -> AXUIElement? {
        let ax = SnapZoneMath.axPoint(
            fromCocoa: NSEvent.mouseLocation, primaryScreenHeight: primaryScreenHeight
        )
        var element: AXUIElement?
        let system = AXUIElementCreateSystemWide()
        guard AXUIElementCopyElementAtPosition(system, Float(ax.x), Float(ax.y), &element) == .success,
              let element else { return nil }
        // Element may be a button/toolbar — resolve its containing window.
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowRef) == .success,
           let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() {
            return (windowRef as! AXUIElement)
        }
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
           role as? String == kAXWindowRole {
            return element
        }
        return nil
    }

    static func origin(of window: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        AXValueGetValue(value as! AXValue, .cgPoint, &point)
        return point
    }

    /// `frame` is in AppKit coordinates; converts to AX top-left before setting.
    static func setFrame(_ frame: CGRect, of window: AXUIElement) {
        var origin = SnapZoneMath.axPoint(
            fromCocoa: CGPoint(x: frame.minX, y: frame.maxY),
            primaryScreenHeight: primaryScreenHeight
        )
        var size = frame.size
        if let value = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        }
    }
}
