# NotchDeck Phase 5 — MacNotch Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the functional gap between NotchDeck and the original MacNotch (macnotch.io): add Window Snap Zones, keyboard shortcuts + notch snooze, screen-capture hiding, the drop-to-act tile grid with new actions, live-activity rotation, and deepen 10 existing modules.

**Architecture:** Every feature slots into the existing `NotchModule` protocol / `ModuleRegistry` / `NotchShellController` architecture (one `NotchPanel` per screen, SwiftUI content, event-driven — no polling while collapsed). Pure logic goes in `public` types so the zero-dependency `NotchDeckChecks` executable can test it; AppKit/AX glue stays thin and untested.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI + AppKit, EventKit, AVFoundation (mirror), Carbon HIToolbox (hotkeys), ApplicationServices/AX (window snap). Zero third-party dependencies. Built with Command Line Tools only (no Xcode, no XCTest).

## Global Constraints

- macOS 14.0+ (`LSMinimumSystemVersion` stays `14.0`).
- Swift 6 strict concurrency: UI/controller classes are `@MainActor`; callbacks hopping threads use `MainActor.assumeIsolated` inside `DispatchQueue.main.async` or `Task { @MainActor in … }`.
- No new SwiftPM dependencies. Only system frameworks.
- Tests are plain assertions in `Sources/NotchDeckChecks/main.swift` using the existing `expect(_:_:)` helper. Anything tested must be `public` in `NotchDeckKit`.
- Test command: `swift run NotchDeckChecks` (prints `FAIL file:line — message` per failure; exit code non-zero on failure).
- Build command: `swift build` for compile checks; `bash scripts/bundle.sh` for the release .app; manual verify with `open dist/NotchDeck.app`.
- Event-driven: no timers while collapsed except existing 0.5 s brightness diff and the new 6 s live-activity rotation tick (TimelineView-driven, coalesced by SwiftUI).
- Modules default to enabled; every new feature is toggleable from Settings.
- Match existing style: compact SwiftUI, `Theme` constants, `HeaderPill` / `CircleIconButton` shared controls, comments only for non-obvious constraints.
- Commit after every task with the message given in that task.

## Explicitly Out of Scope (do not build)

- Licensing/trial/Setapp/Stripe, Sparkle auto-updates, usage-sharing telemetry, Support/feedback module — commercial infrastructure, not product behavior.
- Notification **reply** and true Notification Center clearing — no public API; we implement local dismiss only (Task 17).
- Real FFT audio spectrum — the visualization is animation-driven (like the equalizer bars), not audio capture.
- Per-display picker UI (existing "Show on all displays" toggle stays).
- Intel/universal binary (build stays arm64; noting `arch -x86_64` builds would work is enough).

---

### Task 1: Hide NotchDeck from screenshots, recordings, and screen sharing

MacNotch: "Show Notch in Screenshots & Recordings" toggle (General settings). `NSWindow.sharingType = .none` excludes a window from capture.

**Files:**
- Modify: `Sources/NotchDeckKit/Settings/SettingsStore.swift`
- Modify: `Sources/NotchDeckKit/Settings/SettingsWindow.swift`
- Modify: `Sources/NotchDeckKit/Shell/NotchShellController.swift`

**Interfaces:**
- Produces: `SettingsStore.showInScreenCapture: Bool` (`@Published`, default `true`, defaults key `"showInScreenCapture"`), and `NotchShellController` applying it to every panel.

- [ ] **Step 1: Add the setting**

In `SettingsStore.swift`, add alongside the other `@Published` properties:

```swift
@Published var showInScreenCapture: Bool {
    didSet {
        defaults.set(showInScreenCapture, forKey: "showInScreenCapture")
        onDisplayConfigChange?()
    }
}
```

and in `init()`:

```swift
showInScreenCapture = defaults.object(forKey: "showInScreenCapture") as? Bool ?? true
```

- [ ] **Step 2: Apply to panels**

In `NotchShellController.addPanel(for:modules:)`, right after `let panel = NotchPanel(frame: …)`:

```swift
panel.sharingType = settings.showInScreenCapture ? .readOnly : .none
```

(`onDisplayConfigChange` already triggers `rebuildPanels()`, so toggling rebuilds with the new sharing type.)

- [ ] **Step 3: Add the toggle to Settings**

In `SettingsWindow.swift`, `Section("General")`:

```swift
Toggle("Show notch in screenshots & recordings", isOn: $settings.showInScreenCapture)
```

- [ ] **Step 4: Build and verify**

Run: `swift build` → succeeds. Manual: `bash scripts/bundle.sh && open dist/NotchDeck.app`, toggle off, press ⇧⌘3 — the notch strip must not appear in the screenshot.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: hide notch from screen capture (Settings > General)"
```

---

### Task 2: Notch vertical nudge ("Nudge notch vs menu bar")

MacNotch fixes "notch sits below the menu bar" with a vertical alignment nudge. Pure geometry change + a Settings stepper.

**Files:**
- Modify: `Sources/NotchDeckKit/Shell/NotchGeometry.swift`
- Modify: `Sources/NotchDeckKit/Shell/NotchShellController.swift`
- Modify: `Sources/NotchDeckKit/Settings/SettingsStore.swift`
- Modify: `Sources/NotchDeckKit/Settings/SettingsWindow.swift`
- Test: `Sources/NotchDeckChecks/main.swift`

**Interfaces:**
- Produces: `NotchGeometry.notchRect(screenFrame:safeTopInset:auxTopLeftWidth:auxTopRightWidth:verticalNudge:)` — new trailing parameter `verticalNudge: CGFloat = 0` (positive moves the rect up, clamped so it never leaves the screen top); `SettingsStore.notchNudge: Double` (key `"notchNudge"`, default 0).

- [ ] **Step 1: Write the failing check**

Append to `Sources/NotchDeckChecks/main.swift` under the NotchGeometry section:

```swift
let nudged = NotchGeometry.notchRect(
    screenFrame: screen, safeTopInset: 32, auxTopLeftWidth: 653, auxTopRightWidth: 653,
    verticalNudge: 4
)
expect(nudged.maxY == screen.maxY, "nudge keeps rect pinned to top edge")
expect(nudged.height == 28, "positive nudge shrinks height so bottom rises: \(nudged.height)")
let overNudged = NotchGeometry.notchRect(
    screenFrame: screen, safeTopInset: 32, auxTopLeftWidth: 653, auxTopRightWidth: 653,
    verticalNudge: 100
)
expect(overNudged.height >= 8, "nudge clamps to minimum height")
```

- [ ] **Step 2: Run to verify failure**

Run: `swift run NotchDeckChecks` — expect compile error (extra argument `verticalNudge`).

- [ ] **Step 3: Implement**

In `NotchGeometry.swift`, change the signature and physical-notch branch:

```swift
public static func notchRect(
    screenFrame: CGRect,
    safeTopInset: CGFloat,
    auxTopLeftWidth: CGFloat?,
    auxTopRightWidth: CGFloat?,
    verticalNudge: CGFloat = 0
) -> CGRect {
    if let left = auxTopLeftWidth, let right = auxTopRightWidth, safeTopInset > 0 {
        let height = max(8, safeTopInset - verticalNudge)
        return CGRect(
            x: screenFrame.minX + left,
            y: screenFrame.maxY - height,
            width: screenFrame.width - left - right,
            height: height
        )
    }
    let s = simulatedNotchSize
    let height = max(8, s.height - verticalNudge)
    return CGRect(
        x: screenFrame.midX - s.width / 2,
        y: screenFrame.maxY - height,
        width: s.width,
        height: height
    )
}
```

In `SettingsStore.swift` add:

```swift
@Published var notchNudge: Double {
    didSet {
        defaults.set(notchNudge, forKey: "notchNudge")
        onDisplayConfigChange?()
    }
}
```

init: `notchNudge = defaults.double(forKey: "notchNudge")`

In `NotchShellController.notchRect(for:)`, pass it through. The method is `static`, so read defaults directly there:

```swift
private static func notchRect(for screen: NSScreen) -> CGRect {
    let hasNotch = screen.safeAreaInsets.top > 0
    return NotchGeometry.notchRect(
        screenFrame: screen.frame,
        safeTopInset: screen.safeAreaInsets.top,
        auxTopLeftWidth: hasNotch ? screen.auxiliaryTopLeftArea?.width : nil,
        auxTopRightWidth: hasNotch ? screen.auxiliaryTopRightArea?.width : nil,
        verticalNudge: CGFloat(UserDefaults.standard.double(forKey: "notchNudge"))
    )
}
```

In `SettingsWindow.swift`, `Section("General")`:

```swift
HStack {
    Text("Nudge notch vs menu bar")
    Slider(value: $settings.notchNudge, in: -8...12, step: 1)
    Text("\(Int(settings.notchNudge)) pt").monospacedDigit()
}
```

- [ ] **Step 4: Run checks**

Run: `swift run NotchDeckChecks` — all pass.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: vertical notch nudge setting"
```

---

### Task 3: Snap Zones — pure layout math

MacNotch Window Snap: drag a window toward the top of the screen → layout tiles appear in the notch (halves, thirds, quarters, maximize). This task builds only the pure, testable geometry; Tasks 4–5 add AX and UI.

**Files:**
- Create: `Sources/NotchDeckKit/Modules/Snap/SnapLayout.swift`
- Test: `Sources/NotchDeckChecks/main.swift`

**Interfaces:**
- Produces (all `public`, all consumed by Tasks 4–5):
  - `enum SnapLayout: String, CaseIterable, Codable, Sendable` with cases `leftHalf, rightHalf, maximize, leftThird, centerThird, rightThird, topLeftQuarter, topRightQuarter, bottomLeftQuarter, bottomRightQuarter`; `func frame(in visible: CGRect) -> CGRect`; `var title: String`; `var icon: String` (SF Symbol).
  - `enum SnapZoneMath` with `stripFrame(notch: CGRect, tileCount: Int) -> CGRect`, `tileRects(strip: CGRect, count: Int) -> [CGRect]`, `tileIndex(at point: CGPoint, strip: CGRect, count: Int) -> Int?`, `axPoint(fromCocoa point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint`.

- [ ] **Step 1: Write the failing checks**

Append to `Sources/NotchDeckChecks/main.swift`:

```swift
// MARK: - SnapLayout

let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
expect(SnapLayout.leftHalf.frame(in: visible) == CGRect(x: 0, y: 0, width: 500, height: 800), "left half")
expect(SnapLayout.rightHalf.frame(in: visible) == CGRect(x: 500, y: 0, width: 500, height: 800), "right half")
expect(SnapLayout.maximize.frame(in: visible) == visible, "maximize fills visible frame")
expect(SnapLayout.centerThird.frame(in: visible).minX.rounded() == 333, "center third x")
expect(SnapLayout.topLeftQuarter.frame(in: visible) == CGRect(x: 0, y: 400, width: 500, height: 400), "top-left quarter (AppKit origin bottom-left → top row has higher y)")
expect(SnapLayout.bottomRightQuarter.frame(in: visible) == CGRect(x: 500, y: 0, width: 500, height: 400), "bottom-right quarter")

let strip = SnapZoneMath.stripFrame(notch: CGRect(x: 653, y: 950, width: 206, height: 32), tileCount: 5)
expect(strip.midX == 756, "strip centered on notch: \(strip.midX)")
expect(strip.maxY == 950, "strip hangs below the notch bottom")
let tiles = SnapZoneMath.tileRects(strip: strip, count: 5)
expect(tiles.count == 5, "one rect per tile")
expect(tiles[0].minX >= strip.minX && tiles[4].maxX <= strip.maxX, "tiles fit inside strip")
expect(SnapZoneMath.tileIndex(at: CGPoint(x: tiles[2].midX, y: tiles[2].midY), strip: strip, count: 5) == 2, "hit test middle tile")
expect(SnapZoneMath.tileIndex(at: CGPoint(x: strip.minX - 50, y: strip.midY), strip: strip, count: 5) == nil, "miss outside strip")
expect(SnapZoneMath.axPoint(fromCocoa: CGPoint(x: 10, y: 700), primaryScreenHeight: 800) == CGPoint(x: 10, y: 100), "cocoa→AX y-flip")
```

- [ ] **Step 2: Run to verify failure**

Run: `swift run NotchDeckChecks` — compile error (`SnapLayout` unresolved).

- [ ] **Step 3: Implement `SnapLayout.swift`**

```swift
import CoreGraphics

/// Window layouts offered by Snap Zones. Frames use AppKit coordinates
/// (origin bottom-left) within a screen's visibleFrame.
public enum SnapLayout: String, CaseIterable, Codable, Sendable {
    case leftHalf, rightHalf, maximize
    case leftThird, centerThird, rightThird
    case topLeftQuarter, topRightQuarter, bottomLeftQuarter, bottomRightQuarter

    public func frame(in v: CGRect) -> CGRect {
        let w2 = v.width / 2, h2 = v.height / 2, w3 = v.width / 3
        switch self {
        case .leftHalf: return CGRect(x: v.minX, y: v.minY, width: w2, height: v.height)
        case .rightHalf: return CGRect(x: v.minX + w2, y: v.minY, width: w2, height: v.height)
        case .maximize: return v
        case .leftThird: return CGRect(x: v.minX, y: v.minY, width: w3, height: v.height)
        case .centerThird: return CGRect(x: v.minX + w3, y: v.minY, width: w3, height: v.height)
        case .rightThird: return CGRect(x: v.minX + w3 * 2, y: v.minY, width: w3, height: v.height)
        case .topLeftQuarter: return CGRect(x: v.minX, y: v.minY + h2, width: w2, height: h2)
        case .topRightQuarter: return CGRect(x: v.minX + w2, y: v.minY + h2, width: w2, height: h2)
        case .bottomLeftQuarter: return CGRect(x: v.minX, y: v.minY, width: w2, height: h2)
        case .bottomRightQuarter: return CGRect(x: v.minX + w2, y: v.minY, width: w2, height: h2)
        }
    }

    public var title: String {
        switch self {
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .maximize: "Maximize"
        case .leftThird: "Left Third"
        case .centerThird: "Center Third"
        case .rightThird: "Right Third"
        case .topLeftQuarter: "Top Left"
        case .topRightQuarter: "Top Right"
        case .bottomLeftQuarter: "Bottom Left"
        case .bottomRightQuarter: "Bottom Right"
        }
    }

    public var icon: String {
        switch self {
        case .leftHalf: "rectangle.lefthalf.inset.filled"
        case .rightHalf: "rectangle.righthalf.inset.filled"
        case .maximize: "rectangle.inset.filled"
        case .leftThird: "rectangle.leadingthird.inset.filled"
        case .centerThird: "rectangle.center.inset.filled"
        case .rightThird: "rectangle.trailingthird.inset.filled"
        case .topLeftQuarter: "rectangle.inset.topleading.filled"
        case .topRightQuarter: "rectangle.inset.toptrailing.filled"
        case .bottomLeftQuarter: "rectangle.inset.bottomleading.filled"
        case .bottomRightQuarter: "rectangle.inset.bottomtrailing.filled"
        }
    }
}

/// Pure geometry for the tile strip that appears under the notch.
public enum SnapZoneMath {
    public static let tileSize = CGSize(width: 64, height: 46)
    public static let tileSpacing: CGFloat = 8
    public static let stripPadding: CGFloat = 12

    /// Strip hangs from the bottom edge of the notch, horizontally centered.
    public static func stripFrame(notch: CGRect, tileCount: Int) -> CGRect {
        let width = CGFloat(tileCount) * tileSize.width
            + CGFloat(max(0, tileCount - 1)) * tileSpacing + stripPadding * 2
        let height = tileSize.height + stripPadding * 2
        return CGRect(
            x: notch.midX - width / 2,
            y: notch.minY - height,
            width: width,
            height: height
        )
    }

    public static func tileRects(strip: CGRect, count: Int) -> [CGRect] {
        (0..<count).map { i in
            CGRect(
                x: strip.minX + stripPadding + CGFloat(i) * (tileSize.width + tileSpacing),
                y: strip.minY + stripPadding,
                width: tileSize.width,
                height: tileSize.height
            )
        }
    }

    public static func tileIndex(at point: CGPoint, strip: CGRect, count: Int) -> Int? {
        tileRects(strip: strip, count: count).firstIndex { $0.contains(point) }
    }

    /// AX APIs use top-left-origin global coordinates.
    public static func axPoint(fromCocoa point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }
}
```

- [ ] **Step 4: Run checks**

Run: `swift run NotchDeckChecks` — all pass.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: snap zone layout + strip geometry (pure, tested)"
```

---

### Task 4: Snap Zones — window drag monitor and AX snapper

**Files:**
- Create: `Sources/NotchDeckKit/Modules/Snap/WindowDragMonitor.swift`
- Create: `Sources/NotchDeckKit/Modules/Snap/AXWindowSnapper.swift`

**Interfaces:**
- Consumes: `SnapZoneMath.axPoint(fromCocoa:primaryScreenHeight:)` (Task 3).
- Produces:
  - `@MainActor final class WindowDragMonitor` — `var onDragChanged: ((CGPoint, Bool) -> Void)?` (point in Cocoa coords, `Bool` = a window is being dragged), `var onDragEnded: ((CGPoint) -> Void)?`, `var draggedWindow: AXUIElement?`, `func start()`, `func stop()`.
  - `enum AXWindowSnapper` — `static func isTrusted(prompt: Bool) -> Bool`, `static func windowUnderPointer() -> AXUIElement?`, `static func setFrame(_ frame: CGRect, of window: AXUIElement)`, `static func origin(of window: AXUIElement) -> CGPoint?`.

No pure logic here (all AX/AppKit side effects) — verification is by build + manual test in Task 5.

- [ ] **Step 1: Implement `AXWindowSnapper.swift`**

```swift
import AppKit
import ApplicationServices

/// Thin wrapper over the Accessibility API for reading and moving other
/// apps' windows. Requires the user to trust NotchDeck in
/// System Settings → Privacy & Security → Accessibility.
enum AXWindowSnapper {
    static func isTrusted(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
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
```

- [ ] **Step 2: Implement `WindowDragMonitor.swift`**

```swift
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
```

- [ ] **Step 3: Build**

Run: `swift build` — succeeds (nothing references these yet).

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: AX window snapper + global window-drag monitor"
```

---

### Task 5: Snap Zones — controller, notch tile strip UI, settings

**Files:**
- Create: `Sources/NotchDeckKit/Modules/Snap/SnapZonesController.swift`
- Create: `Sources/NotchDeckKit/Modules/Snap/SnapZoneStripView.swift`
- Modify: `Sources/NotchDeckKit/Shell/NotchViewModel.swift`
- Modify: `Sources/NotchDeckKit/Shell/NotchRootView.swift`
- Modify: `Sources/NotchDeckKit/Shell/NotchShellController.swift`
- Modify: `Sources/NotchDeckKit/Settings/SettingsStore.swift`
- Modify: `Sources/NotchDeckKit/Settings/SettingsWindow.swift`

**Interfaces:**
- Consumes: `SnapLayout`, `SnapZoneMath` (Task 3), `WindowDragMonitor`, `AXWindowSnapper` (Task 4).
- Produces:
  - `NotchViewModel.snapZones: [SnapLayout]?` and `snapHighlight: Int?` (both `@Published`).
  - `SettingsStore.snapZonesEnabled: Bool` (key `"snapZonesEnabled"`, default `false` — off until user grants Accessibility) and `snapLayouts: [SnapLayout]` (key `"snapLayouts"`, JSON, default `[.leftHalf, .maximize, .rightHalf, .leftThird, .rightThird]`).
  - `NotchShellController.snapTarget(near point: CGPoint) -> (vm: NotchViewModel, notch: CGRect, screen: NSScreen)?` — the panel whose screen contains the point.

- [ ] **Step 1: Extend `NotchViewModel`**

Add to the published properties:

```swift
/// Non-nil while a window drag near the top edge should show snap tiles.
@Published var snapZones: [SnapLayout]?
@Published var snapHighlight: Int?
```

- [ ] **Step 2: Settings storage**

In `SettingsStore.swift`:

```swift
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
```

init:

```swift
snapZonesEnabled = defaults.bool(forKey: "snapZonesEnabled")
if let data = defaults.data(forKey: "snapLayouts"),
   let decoded = try? JSONDecoder().decode([SnapLayout].self, from: data), !decoded.isEmpty {
    snapLayouts = decoded
} else {
    snapLayouts = [.leftHalf, .maximize, .rightHalf, .leftThird, .rightThird]
}
```

- [ ] **Step 3: Implement `SnapZonesController.swift`**

```swift
import AppKit

/// Orchestrates snap zones: drag monitor → show tiles in the notch panel of
/// the screen being dragged on → snap on release.
@MainActor
final class SnapZonesController {
    private let settings: SettingsStore
    private let monitor = WindowDragMonitor()
    /// Provided by the shell: find the panel/vm for the screen under a point.
    var target: ((CGPoint) -> (vm: NotchViewModel, notch: CGRect, screen: NSScreen)?)?

    private var activeVM: NotchViewModel?
    private var activeStrip: CGRect?
    private var activeScreen: NSScreen?
    /// Snapshot of the window at gesture time — the monitor clears its copy on mouse-up.
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
```

- [ ] **Step 4: Implement `SnapZoneStripView.swift`**

```swift
import SwiftUI

/// Tile row hanging from the notch while a window drag hovers the top edge.
struct SnapZoneStripView: View {
    @ObservedObject var vm: NotchViewModel

    var body: some View {
        if let layouts = vm.snapZones {
            VStack(spacing: 0) {
                NotchShape()
                    .fill(Color.black)
                    .frame(width: vm.notchSize.width, height: vm.notchSize.height)
                HStack(spacing: SnapZoneMath.tileSpacing) {
                    ForEach(Array(layouts.enumerated()), id: \.offset) { index, layout in
                        VStack(spacing: 3) {
                            Image(systemName: layout.icon).font(.system(size: 16))
                            Text(layout.title).font(.system(size: 7))
                        }
                        .frame(width: SnapZoneMath.tileSize.width, height: SnapZoneMath.tileSize.height)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(vm.snapHighlight == index ? Theme.accent.opacity(0.55) : Theme.card)
                        )
                    }
                }
                .padding(SnapZoneMath.stripPadding)
                .background(
                    RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.92))
                )
            }
            .transition(.opacity)
        }
    }
}
```

- [ ] **Step 5: Wire into the shell**

In `NotchRootView.body`, replace the existing `Group { if vm.state == .expanded … }` contents with:

```swift
if vm.snapZones != nil {
    SnapZoneStripView(vm: vm)
        .transition(.opacity)
} else if vm.state == .expanded {
    ExpandedView(vm: vm, registry: registry, modules: modules)
        .transition(.scale(scale: 0.85, anchor: .top).combined(with: .opacity))
} else {
    CollapsedStripView(vm: vm, registry: registry, modules: modules)
        .transition(.opacity)
}
```

In `NotchShellController`:
- Add a property `private var snapController: SnapZonesController?`
- At the end of `show()`:

```swift
let snap = SnapZonesController(settings: settings)
snap.target = { [weak self] point in self?.snapTarget(near: point) }
snapController = snap
snap.syncEnabled()
```

- Add the lookup + panel growth. The strip hangs below the notch, so while zones are visible the panel frame must include it — subscribe to `vm.$snapZones` in `addPanel` (mirror the existing `vm.$state` sink pattern, store the extra `AnyCancellable` in a new `var snapCancellable: AnyCancellable?` field of `ScreenPanel`):

```swift
entry.snapCancellable = vm.$snapZones
    .map { $0 != nil }
    .removeDuplicates()
    .sink { [weak panel] visible in
        guard let panel else { return }
        let strip = SnapZoneMath.stripFrame(notch: notchRect, tileCount: 10)
        let frame = visible
            ? NotchGeometry.panelFrame(
                notch: notchRect,
                expandedSize: CGSize(width: max(strip.width + 40, notchRect.width),
                                     height: notchRect.height + strip.height))
            : Self.stripFrame(notch: notchRect)
        panel.setFrame(frame, display: true)
    }
```

```swift
func snapTarget(near point: CGPoint) -> (vm: NotchViewModel, notch: CGRect, screen: NSScreen)? {
    for entry in screenPanels {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })
        else { continue }
        if entry.notchRect.midX >= screen.frame.minX, entry.notchRect.midX <= screen.frame.maxX {
            return (entry.vm, entry.notchRect, screen)
        }
    }
    return nil
}
```

Also cancel `snapCancellable` in `rebuildPanels()` next to the existing `cancellable?.cancel()`.

- [ ] **Step 6: Settings UI**

In `SettingsWindow.swift`, add a new section after "Modules":

```swift
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
```

Add the pass-through on `NotchShellController`:

```swift
func snapControllerSyncEnabled() { snapController?.syncEnabled() }
```

- [ ] **Step 7: Build, run checks, manual verify**

Run: `swift run NotchDeckChecks` — pass. `swift build` — pass.
Manual: `bash scripts/bundle.sh && open dist/NotchDeck.app` → Settings → enable Snap Zones → grant Accessibility (System Settings) → quit/reopen → toggle on → drag a Finder window to the top edge: tiles appear under the notch; release over "Left Half": window snaps.

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "feat: window snap zones (drag to notch, tile strip, AX snapping)"
```

---

### Task 6: Keyboard shortcuts — KeyCombo + Carbon hotkey center

**Files:**
- Create: `Sources/NotchDeckKit/Modules/Shortcuts/KeyCombo.swift`
- Create: `Sources/NotchDeckKit/Modules/Shortcuts/HotkeyCenter.swift`
- Test: `Sources/NotchDeckChecks/main.swift`

**Interfaces:**
- Produces:
  - `public struct KeyCombo: Codable, Equatable, Sendable { public var keyCode: UInt32; public var carbonModifiers: UInt32 }` with `public init(keyCode:carbonModifiers:)`, `public static func carbonModifiers(fromCocoa raw: UInt) -> UInt32`, `public var display: String`.
  - `@MainActor final class HotkeyCenter` — `static let shared`, `func bind(_ id: String, to combo: KeyCombo?, action: @escaping () -> Void)` (re-binding an id replaces its hotkey; `nil` combo unbinds).

- [ ] **Step 1: Write the failing checks**

Append to `Sources/NotchDeckChecks/main.swift`:

```swift
// MARK: - KeyCombo

// Cocoa flags: command = 1<<20, shift = 1<<17, option = 1<<19, control = 1<<18.
expect(KeyCombo.carbonModifiers(fromCocoa: 1 << 20) == 256, "cmd → carbon cmdKey")
expect(KeyCombo.carbonModifiers(fromCocoa: (1 << 20) | (1 << 17)) == 256 | 512, "cmd+shift")
expect(KeyCombo.carbonModifiers(fromCocoa: (1 << 19) | (1 << 18)) == 2048 | 4096, "opt+ctrl")
let combo = KeyCombo(keyCode: 45, carbonModifiers: 256 | 512) // ⇧⌘N
expect(combo.display == "⇧⌘N", "display renders modifiers+key: \(combo.display)")
let roundTrip = try? JSONDecoder().decode(KeyCombo.self, from: JSONEncoder().encode(combo))
expect(roundTrip == combo, "KeyCombo codable round-trip")
```

- [ ] **Step 2: Run to verify failure**

Run: `swift run NotchDeckChecks` — compile error (`KeyCombo` unresolved).

- [ ] **Step 3: Implement `KeyCombo.swift`**

```swift
import Foundation

/// A recorded global shortcut. Modifiers use Carbon flag values so they can
/// feed RegisterEventHotKey directly.
public struct KeyCombo: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var carbonModifiers: UInt32

    public init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    // Carbon: cmdKey 256, shiftKey 512, optionKey 2048, controlKey 4096.
    public static func carbonModifiers(fromCocoa raw: UInt) -> UInt32 {
        var flags: UInt32 = 0
        if raw & (1 << 20) != 0 { flags |= 256 }
        if raw & (1 << 17) != 0 { flags |= 512 }
        if raw & (1 << 19) != 0 { flags |= 2048 }
        if raw & (1 << 18) != 0 { flags |= 4096 }
        return flags
    }

    public var display: String {
        var out = ""
        if carbonModifiers & 4096 != 0 { out += "⌃" }
        if carbonModifiers & 2048 != 0 { out += "⌥" }
        if carbonModifiers & 512 != 0 { out += "⇧" }
        if carbonModifiers & 256 != 0 { out += "⌘" }
        return out + Self.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        let names: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
            31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K",
            45: "N", 46: "M", 49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 53: "⎋",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        ]
        return names[code] ?? "key\(code)"
    }
}
```

- [ ] **Step 4: Implement `HotkeyCenter.swift`**

```swift
import AppKit
import Carbon.HIToolbox

/// Registers app-global hotkeys via Carbon (no Accessibility permission
/// needed, and the combos are consumed rather than observed).
@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    private var refs: [String: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var idsByName: [String: UInt32] = [:]
    private var nextID: UInt32 = 1
    private var handlerInstalled = false

    func bind(_ name: String, to combo: KeyCombo?, action: @escaping () -> Void) {
        if let existing = refs.removeValue(forKey: name) {
            UnregisterEventHotKey(existing)
            if let id = idsByName.removeValue(forKey: name) { actions[id] = nil }
        }
        guard let combo else { return }
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4E44_484B) /* 'NDHK' */, id: id)
        let status = RegisterEventHotKey(
            combo.keyCode, combo.carbonModifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &hotKeyRef
        )
        guard status == noErr, let hotKeyRef else { return }
        refs[name] = hotKeyRef
        idsByName[name] = id
        actions[id] = action
    }

    fileprivate func fire(_ id: UInt32) { actions[id]?() }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            let id = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotkeyCenter.shared.fire(id) }
            }
            return noErr
        }, 1, &eventType, nil, nil)
    }
}
```

- [ ] **Step 5: Run checks**

Run: `swift run NotchDeckChecks` — pass. `swift build` — pass.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: KeyCombo (tested) + Carbon hotkey center"
```

---

### Task 7: Shortcut actions, notch snooze, and recorder UI

**Files:**
- Create: `Sources/NotchDeckKit/Modules/Shortcuts/ShortcutSettings.swift`
- Modify: `Sources/NotchDeckKit/Shell/NotchShellController.swift`
- Modify: `Sources/NotchDeckKit/App/StatusItemController.swift`
- Modify: `Sources/NotchDeckKit/Settings/SettingsWindow.swift`

**Interfaces:**
- Consumes: `HotkeyCenter.bind(_:to:action:)`, `KeyCombo` (Task 6).
- Produces:
  - `NotchShellController.toggleFirstPanel()`, `cycleModule(by delta: Int)`, `snooze(minutes: Int)`, `wake()`, `var isSnoozed: Bool`.
  - `@MainActor final class ShortcutSettings: ObservableObject` — `@Published var toggleNotch/nextModule/prevModule/snooze: KeyCombo?` persisted as JSON under keys `"hotkey.toggle"`, `"hotkey.next"`, `"hotkey.prev"`, `"hotkey.snooze"`; `func rebindAll(shell: NotchShellController)`.
  - `struct ShortcutRecorderField: View` — `init(title: String, combo: Binding<KeyCombo?>)`.

- [ ] **Step 1: Shell actions**

Add to `NotchShellController`:

```swift
private var snoozeTask: Task<Void, Never>?
private(set) var isSnoozed = false

func toggleFirstPanel() {
    guard let entry = screenPanels.first else { return }
    entry.vm.state == .expanded ? entry.vm.collapse() : entry.vm.expand()
}

func cycleModule(by delta: Int) {
    guard let entry = screenPanels.first else { return }
    let panels = registry.panelModules
    guard !panels.isEmpty else { return }
    let currentIndex = panels.firstIndex { $0.id == entry.vm.selectedModuleID } ?? 0
    let next = (currentIndex + delta + panels.count) % panels.count
    entry.vm.expand(showing: panels[next].id)
}

func snooze(minutes: Int) {
    isSnoozed = true
    snoozeTask?.cancel()
    for entry in screenPanels { entry.panel.orderOut(nil) }
    snoozeTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(minutes * 60))
        guard !Task.isCancelled else { return }
        self?.wake()
    }
}

func wake() {
    snoozeTask?.cancel()
    isSnoozed = false
    for entry in screenPanels { entry.panel.orderFrontRegardless() }
}
```

- [ ] **Step 2: Implement `ShortcutSettings.swift`**

```swift
import SwiftUI

@MainActor
final class ShortcutSettings: ObservableObject {
    static let shared = ShortcutSettings()

    @Published var toggleNotch: KeyCombo? { didSet { save("hotkey.toggle", toggleNotch) } }
    @Published var nextModule: KeyCombo? { didSet { save("hotkey.next", nextModule) } }
    @Published var prevModule: KeyCombo? { didSet { save("hotkey.prev", prevModule) } }
    @Published var snooze: KeyCombo? { didSet { save("hotkey.snooze", snooze) } }
    @Published var snoozeMinutes: Int {
        didSet { UserDefaults.standard.set(snoozeMinutes, forKey: "hotkey.snoozeMinutes") }
    }

    init() {
        toggleNotch = Self.load("hotkey.toggle")
        nextModule = Self.load("hotkey.next")
        prevModule = Self.load("hotkey.prev")
        snooze = Self.load("hotkey.snooze")
        let stored = UserDefaults.standard.integer(forKey: "hotkey.snoozeMinutes")
        snoozeMinutes = stored == 0 ? 15 : stored
    }

    func rebindAll(shell: NotchShellController) {
        HotkeyCenter.shared.bind("toggle", to: toggleNotch) { [weak shell] in
            shell?.toggleFirstPanel()
        }
        HotkeyCenter.shared.bind("next", to: nextModule) { [weak shell] in
            shell?.cycleModule(by: 1)
        }
        HotkeyCenter.shared.bind("prev", to: prevModule) { [weak shell] in
            shell?.cycleModule(by: -1)
        }
        HotkeyCenter.shared.bind("snooze", to: snooze) { [weak shell] in
            guard let shell else { return }
            shell.isSnoozed ? shell.wake() : shell.snooze(minutes: ShortcutSettings.shared.snoozeMinutes)
        }
    }

    private func save(_ key: String, _ combo: KeyCombo?) {
        if let combo, let data = try? JSONEncoder().encode(combo) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static func load(_ key: String) -> KeyCombo? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(KeyCombo.self, from: data)
    }
}

/// Click, press a combo, done. Esc cancels; ⌫ clears.
struct ShortcutRecorderField: View {
    let title: String
    @Binding var combo: KeyCombo?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button(recording ? "Press keys…" : (combo?.display ?? "Record")) {
                recording ? stop() : start()
            }
        }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            defer { stop() }
            if event.keyCode == 53 { return nil } // Esc = cancel
            if event.keyCode == 51 { combo = nil; return nil } // Delete = clear
            let mods = KeyCombo.carbonModifiers(fromCocoa: event.modifierFlags.rawValue)
            guard mods != 0 else { return nil } // require at least one modifier
            combo = KeyCombo(keyCode: UInt32(event.keyCode), carbonModifiers: mods)
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}
```

- [ ] **Step 3: Bind at startup and expose in Settings**

In `NotchShellController.show()`, after `rebuildPanels()`:

```swift
ShortcutSettings.shared.rebindAll(shell: self)
```

In `SettingsWindow.swift` add a section (needs `@ObservedObject private var shortcuts = ShortcutSettings.shared` on `SettingsView`):

```swift
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
```

with a helper on `SettingsView`:

```swift
private func rebind() {
    if let shell = NotchShellControllerShared.instance {
        ShortcutSettings.shared.rebindAll(shell: shell)
    }
}
```

- [ ] **Step 4: Status-bar snooze menu**

In `StatusItemController.init`, before the separator:

```swift
let snoozeItem = NSMenuItem(title: "Snooze Notch 15 min", action: #selector(snooze), keyEquivalent: "")
snoozeItem.target = self
menu.addItem(snoozeItem)
let wakeItem = NSMenuItem(title: "Wake Notch", action: #selector(wake), keyEquivalent: "")
wakeItem.target = self
menu.addItem(wakeItem)
```

and the handlers:

```swift
@objc private func snooze() { NotchShellControllerShared.instance?.snooze(minutes: 15) }
@objc private func wake() { NotchShellControllerShared.instance?.wake() }
```

- [ ] **Step 5: Build + manual verify**

Run: `swift build` — pass. Manual: record ⇧⌘N as "Toggle notch"; press it with another app focused — notch expands. Menu bar → Snooze — strip disappears; Wake — returns.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: global shortcuts (toggle/next/prev/snooze) + notch snooze"
```

---

### Task 8: New drop actions — unzip, trash, eject, Music, iCloud Drive

MacNotch's drop tiles include unzip, "Trash / Eject" (delete files or eject disks), Music, and cloud save. Extend the pure `DropActionRunner` first.

**Files:**
- Modify: `Sources/NotchDeckKit/Modules/Drop/DropActions.swift`
- Test: `Sources/NotchDeckChecks/main.swift`

**Interfaces:**
- Produces (all on `public enum DropActionRunner`):
  - `static func unzip(_ url: URL) throws -> URL` — extracts next to the archive into a unique folder named after it, returns the folder.
  - `static func trash(_ urls: [URL]) throws` — `FileManager.trashItem`.
  - `static func volumeRoot(for url: URL) -> URL?` — `/Volumes/Name/…` → `/Volumes/Name`, else nil. Pure.
  - `static func iCloudDriveURL(home: URL) -> URL` — `home/Library/Mobile Documents/com~apple~CloudDocs`. Pure.
  - `static func saveToICloud(_ urls: [URL]) throws` — copies into the iCloud Drive folder (throws `DropActionError.processFailed("iCloud Drive")` if the folder doesn't exist).

- [ ] **Step 1: Write the failing checks**

Append to `Sources/NotchDeckChecks/main.swift`:

```swift
// MARK: - DropActionRunner (phase 5 actions)

expect(
    DropActionRunner.volumeRoot(for: URL(fileURLWithPath: "/Volumes/USB Stick/photos/a.jpg"))
        == URL(fileURLWithPath: "/Volumes/USB Stick"),
    "volume root extracted"
)
expect(DropActionRunner.volumeRoot(for: URL(fileURLWithPath: "/Users/x/a.txt")) == nil,
       "non-volume path → nil")
expect(DropActionRunner.volumeRoot(for: URL(fileURLWithPath: "/Volumes")) == nil,
       "bare /Volumes → nil")
expect(
    DropActionRunner.iCloudDriveURL(home: URL(fileURLWithPath: "/Users/x")).path
        == "/Users/x/Library/Mobile Documents/com~apple~CloudDocs",
    "iCloud Drive path"
)

// unzip round-trip: zip a temp file, unzip it, expect the payload back.
let tempDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("ndchecks-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
let payload = tempDir.appendingPathComponent("hello.txt")
try! "hello".write(to: payload, atomically: true, encoding: .utf8)
if let archive = try? DropActionRunner.zip([payload]),
   let extracted = try? DropActionRunner.unzip(archive) {
    let inside = extracted.appendingPathComponent("hello.txt")
    expect((try? String(contentsOf: inside, encoding: .utf8)) == "hello", "unzip restores payload")
} else {
    expect(false, "zip/unzip round-trip threw")
}
try? FileManager.default.removeItem(at: tempDir)
```

- [ ] **Step 2: Run to verify failure**

Run: `swift run NotchDeckChecks` — compile error (`volumeRoot` unresolved).

- [ ] **Step 3: Implement in `DropActions.swift`**

Add inside `DropActionRunner`:

```swift
/// Extracts an archive into a unique sibling folder; returns the folder.
public static func unzip(_ url: URL) throws -> URL {
    let parent = url.deletingLastPathComponent()
    let base = url.deletingPathExtension().lastPathComponent
    var destDir = parent.appendingPathComponent(base, isDirectory: true)
    var counter = 2
    while FileManager.default.fileExists(atPath: destDir.path) {
        destDir = parent.appendingPathComponent("\(base) \(counter)", isDirectory: true)
        counter += 1
    }
    try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
    let ditto = Process()
    ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    ditto.arguments = ["-x", "-k", url.path, destDir.path]
    try ditto.run()
    ditto.waitUntilExit()
    guard ditto.terminationStatus == 0 else { throw DropActionError.processFailed("ditto") }
    return destDir
}

public static func trash(_ urls: [URL]) throws {
    for url in urls {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}

/// `/Volumes/Name/…` → `/Volumes/Name`. Anything else is not ejectable.
public static func volumeRoot(for url: URL) -> URL? {
    let parts = url.pathComponents
    guard parts.count >= 3, parts[0] == "/", parts[1] == "Volumes" else { return nil }
    return URL(fileURLWithPath: "/Volumes/\(parts[2])")
}

public static func iCloudDriveURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
    home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
}

public static func saveToICloud(_ urls: [URL]) throws {
    let drive = iCloudDriveURL()
    guard FileManager.default.fileExists(atPath: drive.path) else {
        throw DropActionError.processFailed("iCloud Drive")
    }
    try copy(urls, to: drive)
}
```

(`unzip` builds its own unique-folder loop rather than reusing `uniqueURL(in:base:ext:)`, which always appends a `.ext` suffix — folders have no extension.)

- [ ] **Step 4: Run checks**

Run: `swift run NotchDeckChecks` — all pass (the unzip round-trip runs `/usr/bin/ditto` for real).

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: unzip, trash, eject-root, Music, iCloud drop actions (runner)"
```

---

### Task 9: Drop-to-act tile grid with Expand row

MacNotch shows a grid of action tiles when a file drag hovers the notch; you drop **onto a tile**. An Expand tile reveals a second row. Rework the drop flow: drag-over → tile grid panel; the Shelf remains one of the tiles (current stash behavior).

**Files:**
- Modify: `Sources/NotchDeckKit/Modules/Drop/DropViews.swift`
- Modify: `Sources/NotchDeckKit/Shell/NotchRootView.swift` (drop delegate opens the grid)

**Interfaces:**
- Consumes: `DropActionRunner.unzip/trash/volumeRoot/saveToICloud` (Task 8), existing `run(_:on:)` machinery.
- Produces:
  - `DropGridAction` gains cases: `shelf, unzip, music, trashOrEject, icloud, expand`.
  - `DropModule.gridExpanded: Bool` (`@Published`, transient).
  - `DropModule.handleGridDrop(_ action: DropGridAction, providers: [NSItemProvider])` — resolves URLs then dispatches.
  - `struct DropGridView: View` replaces the empty-shelf drop hint; `ShelfView` keeps showing stashed files below the grid.

- [ ] **Step 1: Extend the action enum**

In `DropViews.swift`, extend `DropGridAction`:

```swift
enum DropGridAction: Hashable {
    case shelf
    case airdrop
    case zip
    case unzip
    case convert(ImageFormat)
    case move
    case copy
    case openWith
    case music
    case trashOrEject
    case icloud
    case expand

    var title: String {
        switch self {
        case .shelf: "Shelf"
        case .airdrop: "AirDrop"
        case .zip: "Zip"
        case .unzip: "Unzip"
        case .convert(let f): f.rawValue.uppercased()
        case .move: "Move…"
        case .copy: "Copy…"
        case .openWith: "Open With"
        case .music: "Music"
        case .trashOrEject: "Trash / Eject"
        case .icloud: "iCloud"
        case .expand: "Expand"
        }
    }

    var icon: String {
        switch self {
        case .shelf: "tray.and.arrow.down.fill"
        case .airdrop: "wifi"
        case .zip: "doc.zipper"
        case .unzip: "shippingbox.and.arrow.backward"
        case .convert: "photo.on.rectangle.angled"
        case .move: "folder"
        case .copy: "doc.on.doc"
        case .openWith: "arrow.up.forward.app"
        case .music: "music.note"
        case .trashOrEject: "trash"
        case .icloud: "icloud.and.arrow.up"
        case .expand: "chevron.down.circle"
        }
    }

    static let firstRow: [DropGridAction] = [.shelf, .airdrop, .zip, .convert(.png), .expand]
    static let secondRow: [DropGridAction] = [.unzip, .move, .copy, .openWith, .music, .trashOrEject, .icloud]
}
```

- [ ] **Step 2: Handle new actions in `DropModule.run(_:on:)`**

Add cases to the existing `switch action`:

```swift
case .shelf:
    pendingFiles.append(contentsOf: urls)
    showStatus("Added to shelf")
case .unzip:
    runOffMain("Unzipping…") {
        for url in urls { _ = try DropActionRunner.unzip(url) }
        return "Unzipped"
    }
case .music:
    let music = URL(fileURLWithPath: "/System/Applications/Music.app")
    NSWorkspace.shared.open(urls, withApplicationAt: music,
                            configuration: NSWorkspace.OpenConfiguration())
    clearPending()
case .trashOrEject:
    let volumes = urls.compactMap { DropActionRunner.volumeRoot(for: $0) }
    if !volumes.isEmpty {
        for volume in Set(volumes) {
            try? NSWorkspace.shared.unmountAndEjectDevice(at: volume)
        }
        showStatus("Ejected")
        clearPending()
    } else {
        runOffMain("Trashing…") {
            try DropActionRunner.trash(urls)
            return "Moved to Trash"
        }
    }
case .icloud:
    runOffMain("Saving to iCloud…") {
        try DropActionRunner.saveToICloud(urls)
        return "Saved to iCloud Drive"
    }
case .expand:
    gridExpanded.toggle()
```

Add the published flag on `DropModule`:

```swift
@Published var gridExpanded = false
```

and reset it in `deactivate()` and after any successful action (`clearPending()` is a good chokepoint — set `gridExpanded = false` there).

Add the provider-based entry point (each tile receives its own drop):

```swift
func handleGridDrop(_ action: DropGridAction, providers: [NSItemProvider]) {
    let box = ProviderBox(providers: providers)
    Task { [weak self] in
        let urls = await FileDropLoader.urls(from: box)
        guard let self, !urls.isEmpty else { return }
        self.run(action, on: urls)
    }
}
```

- [ ] **Step 3: The grid view**

Add to `DropViews.swift`:

```swift
/// Tile grid shown while a drag hovers; each tile is its own drop target.
struct DropGridView: View {
    @ObservedObject var module: DropModule

    var body: some View {
        VStack(spacing: 8) {
            row(DropGridAction.firstRow)
            if module.gridExpanded {
                row(DropGridAction.secondRow)
            }
        }
    }

    private func row(_ actions: [DropGridAction]) -> some View {
        HStack(spacing: 8) {
            ForEach(actions, id: \.self) { action in
                DropTile(action: action, module: module)
            }
        }
    }
}

struct DropTile: View {
    let action: DropGridAction
    @ObservedObject var module: DropModule
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: action.icon).font(.system(size: 15))
            Text(action.title).font(.system(size: 8))
        }
        .frame(width: 74, height: 50)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(targeted ? Theme.accent.opacity(0.5) : Theme.card)
        )
        .onDrop(of: [UTType.fileURL], isTargeted: Binding(
            get: { targeted },
            set: { hovering in
                targeted = hovering
                // Hovering the Expand tile reveals the second row without dropping.
                if hovering, action == .expand { module.gridExpanded = true }
            }
        )) { providers in
            guard action != .expand else { return false }
            module.handleGridDrop(action, providers: providers)
            return true
        }
    }
}
```

- [ ] **Step 4: Show the grid while dragging**

In `ShelfView.body`, insert the grid above the stash area, only while a drag is in flight or the shelf is empty:

```swift
DropGridView(module: module)
```

(place as the first child of the existing `VStack(spacing: 6)`), and change the empty-state hint text to `"Drop onto an action tile — or onto Shelf to stash"`.

In `NotchDropDelegate.performDrop`, keep the existing fallback (dropping on the notch body, not a tile, still stashes to the shelf) — no change needed; `dropEntered` already expands to the Shelf panel where the grid now lives. Bump `DropModule.preferredHeight` from `150` to `210` to fit the grid + stash.

- [ ] **Step 5: Build + manual verify**

Run: `swift build` — pass. Manual: drag a file over the notch → panel opens with tiles; hover "Expand" → second row appears; drop on "Zip" → archive appears next to the file; drop a `/Volumes/...` item on "Trash / Eject" → volume ejects.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: drop-to-act tile grid with Expand second row"
```

---

### Task 10: Live-activity rotation + unread-notifications glance

MacNotch's collapsed strip **rotates** between media, timers, calendar, Bluetooth; an unread-notifications glance joins when Notifications is on. Today NotchDeck shows a fixed priority pick.

**Files:**
- Create: `Sources/NotchDeckKit/Shell/LiveRotation.swift`
- Modify: `Sources/NotchDeckKit/Shell/NotchRootView.swift`
- Modify: `Sources/NotchDeckKit/Modules/Notifications/NotificationsDB.swift` (glance view)
- Test: `Sources/NotchDeckChecks/main.swift`

**Interfaces:**
- Produces:
  - `public enum LiveRotation { public static func pick(count: Int, tick: Int) -> Int? }` — nil when count == 0, else `tick % count`.
  - `NotificationsModule.glanceView() -> AnyView?` — pill with app name + count of items delivered in the last 15 minutes; nil when none.
- Consumes: existing `liveActivityView()` on pomodoro/calendar/bluetooth modules, `HUDLiveView`.

- [ ] **Step 1: Write the failing check**

```swift
// MARK: - LiveRotation

expect(LiveRotation.pick(count: 0, tick: 7) == nil, "no sources → nil")
expect(LiveRotation.pick(count: 3, tick: 0) == 0, "tick 0 → first")
expect(LiveRotation.pick(count: 3, tick: 4) == 1, "wraps modulo count")
```

- [ ] **Step 2: Run to verify failure**

Run: `swift run NotchDeckChecks` — compile error.

- [ ] **Step 3: Implement `LiveRotation.swift`**

```swift
/// Round-robin selection for the collapsed strip's trailing slot.
public enum LiveRotation {
    public static func pick(count: Int, tick: Int) -> Int? {
        guard count > 0 else { return nil }
        return tick % count
    }
}
```

- [ ] **Step 4: Notifications glance**

In `NotificationsDB.swift`, add to `NotificationsModule`:

```swift
func glanceView() -> AnyView? {
    let recent = items.filter { $0.date.timeIntervalSinceNow > -900 }
    guard let newest = recent.first else { return nil }
    let appName = NSWorkspace.shared
        .urlForApplication(withBundleIdentifier: newest.appBundleID)
        .map { FileManager.default.displayName(atPath: $0.path) }
        ?? newest.appBundleID.components(separatedBy: ".").last?.capitalized
        ?? "New"
    return AnyView(
        HStack(spacing: 6) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.accent)
            Text(recent.count == 1 ? appName : "\(recent.count) new")
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .trailing)
    )
}
```

(`NotificationItem` fields are `id`, `appBundleID`, `title`, `subtitle`, `body`, `date` — defined at the top of `NotificationsDB.swift`. Do **not** add new storage.)

- [ ] **Step 5: Rotate the trailing slot**

In `CollapsedStripView`, replace `trailingActivity` selection with a rotating pick. Add `@State private var tick = 0` won't work in a computed context — instead wrap the body's overlay in a `TimelineView`:

```swift
var body: some View {
    TimelineView(.periodic(from: .now, by: 6)) { context in
        strip(tick: Int(context.date.timeIntervalSinceReferenceDate / 6))
    }
}

private func strip(tick: Int) -> some View {
    let leading = leadingActivity
    let trailing = trailingActivity(tick: tick)
    // … existing layout body unchanged, using these two …
}

private func trailingActivity(tick: Int) -> AnyView? {
    // HUD interrupts always win.
    if hud.event != nil, registry.enabledIDs.contains(modules.hud.id) {
        return AnyView(HUDLiveView(controller: hud))
    }
    var candidates: [AnyView] = []
    if registry.enabledIDs.contains(modules.pomodoro.id),
       let v = modules.pomodoro.liveActivityView() { candidates.append(v) }
    if registry.enabledIDs.contains(modules.calendar.id),
       let v = modules.calendar.liveActivityView() { candidates.append(v) }
    if registry.enabledIDs.contains(modules.bluetooth.id),
       let v = modules.bluetooth.liveActivityView() { candidates.append(v) }
    if registry.enabledIDs.contains(modules.notifications.id),
       let v = modules.notifications.glanceView() { candidates.append(v) }
    guard let index = LiveRotation.pick(count: candidates.count, tick: tick) else { return nil }
    return candidates[index]
}
```

The 6 s `TimelineView` tick only exists while the strip view is on screen (collapsed) and is coalesced by SwiftUI — this respects the "no polling" constraint (it drives UI, not I/O).

- [ ] **Step 6: Run checks + build**

Run: `swift run NotchDeckChecks` — pass. `swift build` — pass. Manual: start a Pomodoro and connect AirPods — trailing slot alternates between the two every ~6 s; volume change interrupts with the HUD.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat: rotating live activities + notifications glance"
```

---

### Task 11: Media — hover transport in the strip + spectrum visualization option

MacNotch: "Optional hover-reveal prev/play/next in the collapsed strip", "Bars or spectrum visualization".

**Files:**
- Modify: `Sources/NotchDeckKit/Modules/Media/MediaViews.swift`
- Modify: `Sources/NotchDeckKit/Settings/SettingsStore.swift`

**Interfaces:**
- Consumes: `MediaController.playPause()/nextTrack()/previousTrack()` (existing).
- Produces: `SettingsStore.mediaHoverControls: Bool` (key `"mediaHoverControls"`, default `true`); `SettingsStore.mediaVisualization: String` (key `"mediaVisualization"`, values `"bars"`/`"spectrum"`, default `"bars"`); `struct SpectrumBars: View`.

- [ ] **Step 1: Settings**

In `SettingsStore.swift`:

```swift
@Published var mediaHoverControls: Bool {
    didSet { defaults.set(mediaHoverControls, forKey: "mediaHoverControls") }
}
@Published var mediaVisualization: String {
    didSet { defaults.set(mediaVisualization, forKey: "mediaVisualization") }
}
```

init:

```swift
mediaHoverControls = defaults.object(forKey: "mediaHoverControls") as? Bool ?? true
mediaVisualization = defaults.string(forKey: "mediaVisualization") ?? "bars"
```

In `SettingsWindow.swift` General section:

```swift
Toggle("Show playback controls when hovering the strip", isOn: $settings.mediaHoverControls)
Picker("Media visualization", selection: $settings.mediaVisualization) {
    Text("Bars").tag("bars")
    Text("Spectrum").tag("spectrum")
}
```

- [ ] **Step 2: Spectrum view**

In `MediaViews.swift` add (same animation-driven approach as the existing `EqualizerBars` — look at its implementation in `MediaViews.swift`/`MediaController.swift` and mirror the phase-animation technique; the difference is bar count and mirrored heights):

```swift
/// Denser, center-weighted animated bars — a faux spectrum (no audio taps).
struct SpectrumBars: View {
    let isPlaying: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: !isPlaying)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 1.5) {
                ForEach(0..<12, id: \.self) { i in
                    let center = abs(Double(i) - 5.5) / 5.5 // 0 at center, 1 at edges
                    let wave = (sin(phase * 3 + Double(i) * 1.1) + 1) / 2
                    let height = isPlaying ? 3 + wave * 11 * (1.1 - center) : 2
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: 2, height: height)
                }
            }
        }
    }
}
```

- [ ] **Step 3: Hover transport in the live activity**

Replace `MediaLiveActivityView` with:

```swift
struct MediaLiveActivityView: View {
    @ObservedObject var controller: MediaController
    @State private var hovering = false
    private var settings: (hover: Bool, viz: String) {
        (UserDefaults.standard.object(forKey: "mediaHoverControls") as? Bool ?? true,
         UserDefaults.standard.string(forKey: "mediaVisualization") ?? "bars")
    }

    var body: some View {
        HStack(spacing: 8) {
            ArtworkView(image: controller.artwork, size: 20)
            if hovering && settings.hover {
                HStack(spacing: 7) {
                    Button { controller.previousTrack() } label: {
                        Image(systemName: "backward.fill").font(.system(size: 9))
                    }
                    Button { controller.playPause() } label: {
                        Image(systemName: controller.track?.isPlaying == true
                              ? "pause.fill" : "play.fill").font(.system(size: 10))
                    }
                    Button { controller.nextTrack() } label: {
                        Image(systemName: "forward.fill").font(.system(size: 9))
                    }
                }
                .buttonStyle(.plain)
            } else if settings.viz == "spectrum" {
                SpectrumBars(isPlaying: controller.track?.isPlaying == true)
                    .frame(width: 30, height: 14)
            } else {
                EqualizerBars(isPlaying: controller.track?.isPlaying == true)
                    .frame(width: 16, height: 14)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering = $0 }
    }
}
```

Note: hovering the strip normally expands the panel after 150 ms. Transport clicks race the expansion, which matches MacNotch's behavior of a brief hover window; no debounce change needed.

- [ ] **Step 4: Build + manual verify**

`swift build` — pass. Manual: play in Spotify; hover the artwork side of the strip — prev/play/next appear and work; switch visualization to Spectrum in Settings — denser bars render.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: media hover transport + spectrum visualization option"
```

---

### Task 12: Pomodoro — completion sound + Timer Done overlay

**Files:**
- Modify: `Sources/NotchDeckKit/Modules/Pomodoro/Pomodoro.swift`

**Interfaces:**
- Produces: `PomodoroModule.overlayUntil: Date?` (`@Published`); sound toggle key `"pomodoro.sound"` (default true).

- [ ] **Step 1: Implement**

In `Pomodoro.swift`, add to `PomodoroModule`:

```swift
@Published var overlayUntil: Date?
```

Find the phase-completion site — the function that builds the user notification (`content.title = finished == .work ? "Work session done" : "Break over"`, around line 175) — and add right before the notification is scheduled:

```swift
if UserDefaults.standard.object(forKey: "pomodoro.sound") as? Bool ?? true {
    NSSound(named: "Glass")?.play()
}
overlayUntil = Date().addingTimeInterval(8)
```

(`import AppKit` at the top of the file if not present.)

Update `liveActivityView()` so the overlay wins while fresh:

```swift
func liveActivityView() -> AnyView? {
    if let until = overlayUntil, until > Date() {
        return AnyView(
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11)).foregroundStyle(.green)
                Text("Timer done")
                    .font(.system(size: 10, weight: .bold))
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .trailing)
        )
    }
    // … existing running-timer pill logic stays below …
}
```

In the module's settings view (`settingsView()` — if the module currently has none, add one following the pattern of other modules):

```swift
func settingsView() -> AnyView {
    AnyView(
        Section("Pomodoro") {
            Toggle("Play sound when a session ends", isOn: Binding(
                get: { UserDefaults.standard.object(forKey: "pomodoro.sound") as? Bool ?? true },
                set: { UserDefaults.standard.set($0, forKey: "pomodoro.sound") }
            ))
        }
    )
}
```

- [ ] **Step 2: Build + manual verify**

`swift build` — pass. Manual: set a 1-minute work preset (or temporarily shorten), let it finish: Glass sound plays, "Timer done ✓" pill shows beside the notch for ~8 s.

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat: pomodoro completion sound + timer-done overlay"
```

---

### Task 13: Calendar — search + overdue reminders

MacNotch: "Search loaded items by title …; overdue and other reminder filters."

**Files:**
- Create: `Sources/NotchDeckKit/Modules/Calendar/EventSearch.swift`
- Modify: `Sources/NotchDeckKit/Modules/Calendar/CalendarViews.swift`
- Modify: `Sources/NotchDeckKit/Shell/NotchShellController.swift` (wire tasks module into calendar)
- Test: `Sources/NotchDeckChecks/main.swift`

**Interfaces:**
- Produces: `public enum EventSearch { public static func matches(query: String, in fields: [String?]) -> Bool }` — case/diacritic-insensitive substring; empty query matches everything.
- Consumes: `TasksModule.items` — `TaskItem` (defined inside `TasksModule.swift`) has `id`, `title`, `dueDate: Date?`, `isCompleted`.

- [ ] **Step 1: Write the failing checks**

```swift
// MARK: - EventSearch

expect(EventSearch.matches(query: "", in: ["Standup"]), "empty query matches")
expect(EventSearch.matches(query: "stand", in: ["Standup", nil]), "case-insensitive prefix")
expect(EventSearch.matches(query: "CAFÉ", in: ["team cafe sync"]), "diacritic-insensitive")
expect(!EventSearch.matches(query: "retro", in: ["Standup", "Room 4"]), "no match → false")
```

- [ ] **Step 2: Run to verify failure**

Run: `swift run NotchDeckChecks` — compile error.

- [ ] **Step 3: Implement `EventSearch.swift`**

```swift
import Foundation

public enum EventSearch {
    public static func matches(query: String, in fields: [String?]) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        return fields.compactMap { $0 }.contains {
            $0.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
```

- [ ] **Step 4: Wire into the panel**

In `CalendarViews.swift`:
- Add `@Published var searchText = ""` and `weak var tasks: TasksModule?` to `CalendarModule`.
- In `CalendarPanelView`, above the events list add a compact search field, and filter the list:

```swift
TextField("Search events", text: $module.searchText)
    .textFieldStyle(.roundedBorder)
    .controlSize(.small)
    .frame(maxWidth: 180)
```

```swift
let visibleEvents = source.events.filter {
    EventSearch.matches(query: module.searchText, in: [$0.title])
}
```

(use `visibleEvents` wherever the list currently iterates `source.events`).
- Below the events list, add an overdue section fed by the tasks module:

```swift
if let tasks = module.tasks {
    let overdue = tasks.items.filter { !$0.isCompleted && ($0.dueDate ?? .distantFuture) < Date() }
    if !overdue.isEmpty {
        SectionCaption(text: "Overdue reminders")
        ForEach(overdue.prefix(3)) { item in
            Label(item.title, systemImage: "exclamationmark.circle")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
        }
    }
}
```

(`TaskItem.dueDate` already exists; if `TasksModule.refresh()` doesn't yet populate it, set it from `reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }`.)

In `NotchShellController.show()` alongside the other wiring lines:

```swift
modules.calendar.tasks = modules.tasks
```

- [ ] **Step 5: Run checks + build + commit**

`swift run NotchDeckChecks` — pass. `swift build` — pass.

```bash
git add -A && git commit -m "feat: calendar search + overdue reminders section"
```

---

### Task 14: Tasks — trash with retention + restore

MacNotch: "Add, complete, delete, and restore tasks. Trash with retention."

**Files:**
- Create: `Sources/NotchDeckKit/Modules/Tasks/TaskTrash.swift`
- Modify: `Sources/NotchDeckKit/Modules/Tasks/TasksModule.swift`
- Test: `Sources/NotchDeckChecks/main.swift`

**Interfaces:**
- Produces:
  - `public struct TrashedTask: Codable, Equatable, Sendable { public var id: String; public var title: String; public var deletedAt: Date; public init(id:title:deletedAt:) }`
  - `public enum TaskTrash { public static func pruned(_ entries: [TrashedTask], now: Date, retentionDays: Int) -> [TrashedTask] }`
  - `TasksModule.trashed: [TrashedTask]` (`@Published`, persisted at `Application Support/NotchDeck/tasks-trash.json`, 30-day retention), `func restore(_ entry: TrashedTask)`, and `delete(_:)` now records to trash first.

- [ ] **Step 1: Write the failing checks**

```swift
// MARK: - TaskTrash

let oldEntry = TrashedTask(id: "1", title: "old", deletedAt: Date(timeIntervalSinceNow: -31 * 86_400))
let newEntry = TrashedTask(id: "2", title: "new", deletedAt: Date(timeIntervalSinceNow: -3_600))
let kept = TaskTrash.pruned([oldEntry, newEntry], now: Date(), retentionDays: 30)
expect(kept == [newEntry], "prune drops entries older than retention")
expect(TaskTrash.pruned([], now: Date(), retentionDays: 30).isEmpty, "empty stays empty")
```

- [ ] **Step 2: Run to verify failure**

Run: `swift run NotchDeckChecks` — compile error.

- [ ] **Step 3: Implement `TaskTrash.swift`**

```swift
import Foundation

public struct TrashedTask: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var deletedAt: Date

    public init(id: String, title: String, deletedAt: Date) {
        self.id = id
        self.title = title
        self.deletedAt = deletedAt
    }
}

public enum TaskTrash {
    public static func pruned(
        _ entries: [TrashedTask], now: Date, retentionDays: Int
    ) -> [TrashedTask] {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        return entries.filter { $0.deletedAt > cutoff }
    }
}
```

- [ ] **Step 4: Wire into `TasksModule`**

Add:

```swift
@Published private(set) var trashed: [TrashedTask] = []

private static var trashURL: URL {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NotchDeck", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("tasks-trash.json")
}

private func loadTrash() {
    let entries = (try? Data(contentsOf: Self.trashURL))
        .flatMap { try? JSONDecoder().decode([TrashedTask].self, from: $0) } ?? []
    trashed = TaskTrash.pruned(entries, now: Date(), retentionDays: 30)
    saveTrash()
}

private func saveTrash() {
    if let data = try? JSONEncoder().encode(trashed) {
        try? data.write(to: Self.trashURL, atomically: true)
    }
}

func restore(_ entry: TrashedTask) {
    add(title: entry.title)
    trashed.removeAll { $0.id == entry.id }
    saveTrash()
}
```

Call `loadTrash()` inside `activate()`. Change `delete(_:)` to record first:

```swift
func delete(_ item: TaskItem) {
    trashed.insert(TrashedTask(id: item.id, title: item.title, deletedAt: Date()), at: 0)
    saveTrash()
    guard let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder else { return }
    try? store.remove(reminder, commit: true)
    items.removeAll { $0.id == item.id }
}
```

In `TasksPanelView`, the existing sidebar has Active/Done filters — add a "Trash" entry to the same filter mechanism (extend the `Filter` enum with `case trash`, count = `module.trashed.count`), and when selected render:

```swift
ForEach(module.trashed) { entry in
    HStack {
        Text(entry.title).font(.system(size: 11)).strikethrough()
        Spacer()
        Button("Restore") { module.restore(entry) }.controlSize(.mini)
    }
}
```

- [ ] **Step 5: Run checks + build + commit**

`swift run NotchDeckChecks` — pass. `swift build` — pass.

```bash
git add -A && git commit -m "feat: task trash with 30-day retention and restore"
```

---

### Task 15: Day Progress — full module with event timeline + bedtime marker

MacNotch: "One timeline for today from calendar events, reminders, and tasks, with an optional bedtime marker." Keep the existing dashboard widget; add a dedicated module.

**Files:**
- Create: `Sources/NotchDeckKit/Modules/Dashboard/DayTimeline.swift`
- Create: `Sources/NotchDeckKit/Modules/Dashboard/DayProgressModule.swift`
- Modify: `Sources/NotchDeckKit/Shell/NotchRootView.swift` (register module)
- Modify: `Sources/NotchDeckKit/Shell/NotchShellController.swift` (wire sources)
- Test: `Sources/NotchDeckChecks/main.swift`

**Interfaces:**
- Produces:
  - `public enum DayTimeline` with `public struct Block: Equatable, Sendable { public var startFraction: Double; public var endFraction: Double; public init(startFraction:endFraction:) }`, `public static func fraction(of date: Date, dayStart: Date, dayEnd: Date) -> Double?` (nil outside range, else 0…1), `public static func blocks(events: [(start: Date, end: Date)], dayStart: Date, dayEnd: Date) -> [Block]` (clamped to 0…1, zero-length and out-of-range events dropped).
  - `DayProgressModule` (`moduleID = "dayprogress"`, panel) added to `ModuleSet` between `pomodoro` and `tasks` in `all`.
- Consumes: `CalendarSource.events`, `TasksModule.items`, defaults keys `"dayprogress.start"`, `"dayprogress.end"` (existing) and new `"dayprogress.bedtime"` (Int hour, default 23).

- [ ] **Step 1: Write the failing checks**

```swift
// MARK: - DayTimeline

let dayStart = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
let dayEnd = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: Date())!
let noon = Calendar.current.date(bySettingHour: 13, minute: 30, second: 0, of: Date())!
expect(DayTimeline.fraction(of: noon, dayStart: dayStart, dayEnd: dayEnd) == 0.5, "13:30 is halfway through 9–18")
expect(DayTimeline.fraction(of: dayStart.addingTimeInterval(-60), dayStart: dayStart, dayEnd: dayEnd) == nil, "before start → nil")
let blocks = DayTimeline.blocks(
    events: [(start: dayStart.addingTimeInterval(3_600), end: dayStart.addingTimeInterval(7_200)),
             (start: dayEnd.addingTimeInterval(3_600), end: dayEnd.addingTimeInterval(7_200))],
    dayStart: dayStart, dayEnd: dayEnd
)
expect(blocks.count == 1, "out-of-range event dropped")
expect(abs(blocks[0].startFraction - 1.0 / 9.0) < 0.001, "block start fraction")
```

- [ ] **Step 2: Run to verify failure**

Run: `swift run NotchDeckChecks` — compile error.

- [ ] **Step 3: Implement `DayTimeline.swift`**

```swift
import Foundation

/// Pure math mapping today's events onto a 0…1 working-day timeline.
public enum DayTimeline {
    public struct Block: Equatable, Sendable {
        public var startFraction: Double
        public var endFraction: Double

        public init(startFraction: Double, endFraction: Double) {
            self.startFraction = startFraction
            self.endFraction = endFraction
        }
    }

    public static func fraction(of date: Date, dayStart: Date, dayEnd: Date) -> Double? {
        let total = dayEnd.timeIntervalSince(dayStart)
        guard total > 0 else { return nil }
        let f = date.timeIntervalSince(dayStart) / total
        return (0...1).contains(f) ? f : nil
    }

    public static func blocks(
        events: [(start: Date, end: Date)], dayStart: Date, dayEnd: Date
    ) -> [Block] {
        let total = dayEnd.timeIntervalSince(dayStart)
        guard total > 0 else { return [] }
        return events.compactMap { event in
            let s = max(0, event.start.timeIntervalSince(dayStart) / total)
            let e = min(1, event.end.timeIntervalSince(dayStart) / total)
            guard e > s, s < 1, e > 0 else { return nil }
            return Block(startFraction: s, endFraction: e)
        }
    }
}
```

- [ ] **Step 4: Implement `DayProgressModule.swift`**

```swift
import SwiftUI

@MainActor
final class DayProgressModule: NotchModule, ObservableObject {
    static let moduleID = "dayprogress"
    let id = DayProgressModule.moduleID
    let name = "Day Progress"
    let icon = "chart.bar.fill"
    let hasPanel = true
    var preferredHeight: CGFloat { 150 }

    weak var calendarSource: CalendarSource?
    weak var tasks: TasksModule?

    func activate() {}
    func deactivate() {}
    func panelView() -> AnyView { AnyView(DayProgressPanelView(module: self)) }

    func settingsView() -> AnyView {
        AnyView(
            Section("Day Progress") {
                Stepper(
                    "Bedtime: \(UserDefaults.standard.object(forKey: "dayprogress.bedtime") as? Int ?? 23):00",
                    value: Binding(
                        get: { UserDefaults.standard.object(forKey: "dayprogress.bedtime") as? Int ?? 23 },
                        set: { UserDefaults.standard.set($0, forKey: "dayprogress.bedtime") }
                    ), in: 19...27
                )
            }
        )
    }
}

struct DayProgressPanelView: View {
    @ObservedObject var module: DayProgressModule
    @AppStorage("dayprogress.start") private var startHour = 9
    @AppStorage("dayprogress.end") private var endHour = 18
    @AppStorage("dayprogress.bedtime") private var bedtimeHour = 23

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let calendar = Calendar.current
            let dayStart = calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: context.date)!
            // End/bedtime may cross midnight (hour ≥ 24 handled via addingTimeInterval).
            let dayEnd = dayStart.addingTimeInterval(Double(endHour - startHour) * 3_600)
            let bedtime = dayStart.addingTimeInterval(Double(bedtimeHour - startHour) * 3_600)
            let events = (module.calendarSource?.events ?? []).map { (start: $0.start, end: $0.end) }
            let blocks = DayTimeline.blocks(events: events, dayStart: dayStart, dayEnd: bedtime)
            let nowFraction = DayTimeline.fraction(of: context.date, dayStart: dayStart, dayEnd: bedtime)
            let workEndFraction = DayTimeline.fraction(of: dayEnd, dayStart: dayStart, dayEnd: bedtime)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if let nowFraction {
                        Text("\(Int(nowFraction * 100))% of your day")
                            .font(.system(size: 14, weight: .bold))
                    } else {
                        Text("Outside your day").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(startHour):00 → bed \(bedtimeHour % 24):00")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.1)).frame(height: 10)
                        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                            Capsule()
                                .fill(Theme.accent.opacity(0.6))
                                .frame(
                                    width: max(4, (block.endFraction - block.startFraction) * geo.size.width),
                                    height: 10
                                )
                                .offset(x: block.startFraction * geo.size.width)
                        }
                        if let workEndFraction {
                            Rectangle().fill(Color.orange).frame(width: 2, height: 16)
                                .offset(x: workEndFraction * geo.size.width)
                        }
                        Rectangle().fill(Color.purple).frame(width: 2, height: 16)
                            .offset(x: geo.size.width - 2) // bedtime = end of bar
                        if let nowFraction {
                            Circle().fill(Color.white).frame(width: 8, height: 8)
                                .offset(x: nowFraction * geo.size.width - 4)
                        }
                    }
                }
                .frame(height: 18)
                if let tasks = module.tasks {
                    let open = tasks.items.filter { !$0.isCompleted }.count
                    Text("\(open) open task\(open == 1 ? "" : "s") · \(module.calendarSource?.events.count ?? 0) events today")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        }
    }
}
```

- [ ] **Step 5: Register + wire**

In `NotchRootView.swift` `ModuleSet`: add `let dayProgress: DayProgressModule`, init `dayProgress = DayProgressModule()`, and insert `dayProgress` into `all` after `pomodoro`. In `NotchShellController.show()`:

```swift
modules.dayProgress.calendarSource = modules.calendar.source
modules.dayProgress.tasks = modules.tasks
```

- [ ] **Step 6: Run checks + build + commit**

`swift run NotchDeckChecks` — pass. `swift build` — pass.

```bash
git add -A && git commit -m "feat: day progress module with event timeline + bedtime marker"
```

---

### Task 16: Screen Time — dedicated module (categories, ranked apps, app switches)

MacNotch: "category charts, ranked apps, and app-switch counts in a dedicated notch module." Extend the tracker, add pure categorization, promote to a module (keep the dashboard widget).

**Files:**
- Create: `Sources/NotchDeckKit/Modules/Dashboard/AppCategory.swift`
- Modify: `Sources/NotchDeckKit/Modules/Dashboard/ScreenTime.swift`
- Modify: `Sources/NotchDeckKit/Shell/NotchRootView.swift`
- Test: `Sources/NotchDeckChecks/main.swift`

**Interfaces:**
- Produces:
  - `public enum AppCategory` — `public static func categorize(_ bundleID: String) -> String` (returns one of "Browsing", "Development", "Communication", "Media", "Productivity", "Other"), `public static func totals(_ slices: [UsageSlice]) -> [(category: String, seconds: TimeInterval)]` sorted descending.
  - `AppUsageTracker.todaySwitchCount: Int` (`@Published`, persisted per-day in `screentime-switches.json`), incremented on every frontmost-app change.
  - `ScreenTimeModule` (`moduleID = "screentime"`, panel) in `ModuleSet.all` after `system`. It reuses the dashboard module's tracker: `init(tracker: AppUsageTracker)`, constructed as `ScreenTimeModule(tracker: dashboard.screenTime)` in `ModuleSet.init`.

- [ ] **Step 1: Write the failing checks**

```swift
// MARK: - AppCategory

expect(AppCategory.categorize("com.apple.Safari") == "Browsing", "Safari → Browsing")
expect(AppCategory.categorize("com.google.Chrome") == "Browsing", "Chrome → Browsing")
expect(AppCategory.categorize("com.apple.dt.Xcode") == "Development", "Xcode → Development")
expect(AppCategory.categorize("com.tinyspeck.slackmacgap") == "Communication", "Slack → Communication")
expect(AppCategory.categorize("com.spotify.client") == "Media", "Spotify → Media")
expect(AppCategory.categorize("com.unknown.thing") == "Other", "unknown → Other")
let catTotals = AppCategory.totals([
    UsageSlice(bundleID: "com.apple.Safari", seconds: 100),
    UsageSlice(bundleID: "com.google.Chrome", seconds: 50),
    UsageSlice(bundleID: "com.apple.dt.Xcode", seconds: 120),
])
expect(catTotals.first?.category == "Browsing" && catTotals.first?.seconds == 150,
       "categories aggregate and sort: \(catTotals)")
```

- [ ] **Step 2: Run to verify failure**

Run: `swift run NotchDeckChecks` — compile error.

- [ ] **Step 3: Implement `AppCategory.swift`**

```swift
import Foundation

/// Coarse bundle-ID → category mapping for screen-time charts.
public enum AppCategory {
    static let table: [String: String] = [
        "com.apple.Safari": "Browsing", "com.google.Chrome": "Browsing",
        "org.mozilla.firefox": "Browsing", "com.brave.Browser": "Browsing",
        "company.thebrowser.Browser": "Browsing", "com.microsoft.edgemac": "Browsing",
        "com.apple.dt.Xcode": "Development", "com.microsoft.VSCode": "Development",
        "com.todesktop.230313mzl4w4u92": "Development", "com.googlecode.iterm2": "Development",
        "com.apple.Terminal": "Development", "com.jetbrains.intellij": "Development",
        "com.tinyspeck.slackmacgap": "Communication", "com.hnc.Discord": "Communication",
        "com.apple.MobileSMS": "Communication", "us.zoom.xos": "Communication",
        "com.apple.mail": "Communication", "com.microsoft.teams2": "Communication",
        "com.spotify.client": "Media", "com.apple.Music": "Media",
        "com.apple.TV": "Media", "com.colliderli.iina": "Media", "org.videolan.vlc": "Media",
        "com.apple.iCal": "Productivity", "com.apple.Notes": "Productivity",
        "com.culturedcode.ThingsMac": "Productivity", "com.apple.reminders": "Productivity",
        "md.obsidian": "Productivity", "notion.id": "Productivity",
    ]

    public static func categorize(_ bundleID: String) -> String {
        table[bundleID] ?? "Other"
    }

    public static func totals(_ slices: [UsageSlice]) -> [(category: String, seconds: TimeInterval)] {
        var buckets: [String: TimeInterval] = [:]
        for slice in slices where slice.bundleID != "other" {
            buckets[categorize(slice.bundleID), default: 0] += slice.seconds
        }
        return buckets.sorted { $0.value > $1.value }.map { (category: $0.key, seconds: $0.value) }
    }
}
```

- [ ] **Step 4: Switch counting in `AppUsageTracker`**

In `ScreenTime.swift` add to `AppUsageTracker`:

```swift
@Published private(set) var todaySwitchCount = 0
private var switchCounts: [String: Int] = [:] // dayKey → count

private static var switchesURL: URL {
    fileURL.deletingLastPathComponent().appendingPathComponent("screentime-switches.json")
}
```

In `activate()` after loading the ledger:

```swift
switchCounts = (try? Data(contentsOf: Self.switchesURL))
    .flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
todaySwitchCount = switchCounts[UsageLedger.dayKey(for: Date())] ?? 0
```

In the existing frontmost-app-change handler (the observer that flips `currentBundle` — find where `currentBundle` is reassigned on `didActivateApplicationNotification`), add:

```swift
let key = UsageLedger.dayKey(for: Date())
switchCounts[key, default: 0] += 1
todaySwitchCount = switchCounts[key] ?? 0
if let data = try? JSONEncoder().encode(switchCounts) {
    try? data.write(to: Self.switchesURL, atomically: true)
}
```

Also expose ranked slices: add

```swift
func topSlices(_ count: Int) -> [UsageSlice] { ledger.today(top: count) }
```

- [ ] **Step 5: The module**

Append to `ScreenTime.swift`:

```swift
@MainActor
final class ScreenTimeModule: NotchModule, ObservableObject {
    static let moduleID = "screentime"
    let id = ScreenTimeModule.moduleID
    let name = "Screen Time"
    let icon = "hourglass"
    let hasPanel = true
    var preferredHeight: CGFloat { 200 }

    let tracker: AppUsageTracker

    init(tracker: AppUsageTracker) {
        self.tracker = tracker
    }

    // Tracker lifecycle belongs to the dashboard module (shared instance).
    func activate() {}
    func deactivate() {}

    func panelView() -> AnyView { AnyView(ScreenTimePanelView(tracker: tracker)) }

    func headerBadge() -> AnyView? {
        AnyView(HeaderPill(text: "\(tracker.todaySwitchCount) switches", icon: "arrow.triangle.swap"))
    }
}

struct ScreenTimePanelView: View {
    @ObservedObject var tracker: AppUsageTracker

    var body: some View {
        let slices = tracker.topSlices(8)
        let total = max(slices.reduce(0) { $0 + $1.seconds }, 1)
        let categories = AppCategory.totals(slices)
        HStack(alignment: .top, spacing: 20) {
            VStack(spacing: 8) {
                UsageDonut(slices: slices, total: total, centerText: ScreenTimeTile.duration(total))
                    .frame(width: 84, height: 84)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(categories.prefix(4).enumerated()), id: \.offset) { _, entry in
                        HStack(spacing: 5) {
                            Text(entry.category).font(.system(size: 9))
                            Spacer()
                            Text(ScreenTimeTile.duration(entry.seconds))
                                .font(.system(size: 9).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 130)
            }
            VStack(alignment: .leading, spacing: 4) {
                SectionCaption(text: "Ranked apps")
                ForEach(Array(slices.prefix(6).enumerated()), id: \.offset) { index, slice in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(ScreenTimeTile.palette[index % ScreenTimeTile.palette.count])
                            .frame(width: 6, height: 6)
                        Text(ScreenTimeTile.appName(slice.bundleID)).font(.system(size: 10)).lineLimit(1)
                        Spacer()
                        GeometryReader { geo in
                            Capsule().fill(Color.white.opacity(0.15))
                                .overlay(alignment: .leading) {
                                    Capsule()
                                        .fill(ScreenTimeTile.palette[index % ScreenTimeTile.palette.count])
                                        .frame(width: geo.size.width * slice.seconds / total)
                                }
                        }
                        .frame(width: 90, height: 5)
                        Text(ScreenTimeTile.duration(slice.seconds))
                            .font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { tracker.refresh() }
    }
}
```

Register in `ModuleSet` (`NotchRootView.swift`): add `let screenTime: ScreenTimeModule`, init **after** `dashboard`: `screenTime = ScreenTimeModule(tracker: dashboard.screenTime)`, add to `all` after `system`.

- [ ] **Step 6: Run checks + build + commit**

`swift run NotchDeckChecks` — pass. `swift build` — pass.

```bash
git add -A && git commit -m "feat: screen time module — categories, ranked apps, switch count"
```

---

### Task 17: Notifications — local dismiss and Clear All

Public API cannot clear Notification Center or reply (documented out of scope). Implement local dismissal: hidden items never reappear in the panel.

**Files:**
- Modify: `Sources/NotchDeckKit/Modules/Notifications/NotificationsDB.swift`

**Interfaces:**
- Produces: `NotificationsModule.dismiss(_ id: String)`, `dismissAll()`; dismissed IDs persist in defaults key `"notifications.dismissed"` (capped at 500, newest kept).

- [ ] **Step 1: Implement**

In `NotificationsModule`:

```swift
private var dismissedIDs: Set<String> = []

private func loadDismissed() {
    dismissedIDs = Set(UserDefaults.standard.stringArray(forKey: "notifications.dismissed") ?? [])
}

private func saveDismissed() {
    UserDefaults.standard.set(Array(dismissedIDs.suffix(500)), forKey: "notifications.dismissed")
}

func dismiss(_ id: String) {
    dismissedIDs.insert(id)
    saveDismissed()
    items.removeAll { $0.id == id }
}

func dismissAll() {
    for item in items { dismissedIDs.insert(item.id) }
    saveDismissed()
    items = []
}
```

Call `loadDismissed()` in `activate()` before the first refresh. In `refresh()`, the fresh list lands via `if self.items != items { self.items = items }` (~line 155) — insert the filter just before that comparison:

```swift
let items = items.filter { !self.dismissedIDs.contains($0.id) }
```

In the panel row view, add a hover-revealed dismiss button next to each item:

```swift
Button { module.dismiss(item.id) } label: {
    Image(systemName: "xmark.circle.fill").font(.system(size: 10))
}
.buttonStyle(.plain)
```

and in `headerActions()` (create it if absent):

```swift
func headerActions() -> AnyView? {
    AnyView(
        HeaderPill(text: "Clear all", icon: "xmark") { [weak self] in self?.dismissAll() }
    )
}
```

- [ ] **Step 2: Build + manual verify + commit**

`swift build` — pass. Manual: open Notifications module, dismiss one item — it disappears and stays gone after refresh.

```bash
git add -A && git commit -m "feat: notifications local dismiss + clear all"
```

---

### Task 18: Notes — multiple notes

MacNotch: "Create and open notes from the dashboard for quick capture." Replace the single scratchpad with a notes directory; keep autosave.

**Files:**
- Modify: `Sources/NotchDeckKit/Modules/Notes/NotesModule.swift`

**Interfaces:**
- Produces: `NotesModule.notes: [URL]` (`@Published`, files in `Application Support/NotchDeck/Notes/*.md`, sorted by modification date descending), `selected: URL?`, `createNote()`, `deleteNote(_ url: URL)`, `select(_ url: URL)`. Existing `notes.txt` migrates to `Notes/Scratchpad.md` on first activate.

- [ ] **Step 1: Implement storage**

Rework `NotesModule`:

```swift
@Published var notes: [URL] = []
@Published var selected: URL?
@Published var text: String = "" {
    didSet { if !isLoading { scheduleSave() } }
}
private var isLoading = false

private static var notesDir: URL {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NotchDeck/Notes", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func activate() {
    migrateLegacyNote()
    reloadList()
    if selected == nil { selected = notes.first }
    load(selected)
}

private func migrateLegacyNote() {
    let legacy = Self.notesDir.deletingLastPathComponent().appendingPathComponent("notes.txt")
    let target = Self.notesDir.appendingPathComponent("Scratchpad.md")
    if FileManager.default.fileExists(atPath: legacy.path),
       !FileManager.default.fileExists(atPath: target.path) {
        try? FileManager.default.moveItem(at: legacy, to: target)
    }
}

private func reloadList() {
    let urls = (try? FileManager.default.contentsOfDirectory(
        at: Self.notesDir, includingPropertiesForKeys: [.contentModificationDateKey]
    )) ?? []
    notes = urls.filter { $0.pathExtension == "md" }.sorted {
        let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return a > b
    }
}

func createNote() {
    saveNow()
    let url = DropActionRunner.uniqueURL(in: Self.notesDir, base: "Note", ext: "md")
    try? "".write(to: url, atomically: true, encoding: .utf8)
    reloadList()
    select(url)
}

func deleteNote(_ url: URL) {
    try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
    reloadList()
    if selected == url { selected = notes.first; load(selected) }
}

func select(_ url: URL) {
    saveNow()
    selected = url
    load(url)
}

private func load(_ url: URL?) {
    isLoading = true
    text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    isLoading = false
}

private func saveNow() {
    guard let selected else { return }
    try? text.write(to: selected, atomically: true, encoding: .utf8)
}
```

Keep the existing `scheduleSave()` debounce (it calls `saveNow()`). Title for the list = first non-empty line of the file, else the filename:

```swift
func title(of url: URL) -> String {
    let head = (try? String(contentsOf: url, encoding: .utf8))?
        .split(separator: "\n").first.map(String.init)
    return (head?.isEmpty == false ? head! : url.deletingPathExtension().lastPathComponent)
}
```

- [ ] **Step 2: Panel UI**

In `NotesPanelView` (same file), add a sidebar list:

```swift
HStack(alignment: .top, spacing: 10) {
    VStack(alignment: .leading, spacing: 4) {
        Button { module.createNote() } label: {
            Label("New note", systemImage: "plus").font(.system(size: 10))
        }
        .buttonStyle(.plain)
        ForEach(module.notes, id: \.self) { url in
            Text(module.title(of: url))
                .font(.system(size: 10, weight: url == module.selected ? .bold : .regular))
                .lineLimit(1)
                .onTapGesture { module.select(url) }
                .contextMenu { Button("Delete") { module.deleteNote(url) } }
        }
        Spacer()
    }
    .frame(width: 120, alignment: .leading)
    // existing TextEditor bound to module.text stays as the right column
}
```

Update `headerBadge()` to show the selected note title + word count.

- [ ] **Step 3: Build + manual verify + commit**

`swift build` — pass. Manual: create two notes, type in each, switch between them — content persists per note; old scratchpad content appears as "Scratchpad".

```bash
git add -A && git commit -m "feat: multiple notes with sidebar + legacy migration"
```

---

### Task 19: Dashboard — quotes widget, time-based profile switching

**Files:**
- Create: `Sources/NotchDeckKit/Modules/Dashboard/QuoteBook.swift`
- Create: `Sources/NotchDeckKit/Modules/Dashboard/ProfileSchedule.swift`
- Modify: `Sources/NotchDeckKit/Modules/Dashboard/DashboardModule.swift`
- Test: `Sources/NotchDeckChecks/main.swift`

**Interfaces:**
- Produces:
  - `public enum QuoteBook { public static let quotes: [String]; public static func quote(dayOfYear: Int) -> String }`
  - `public struct ProfileRule: Codable, Equatable, Sendable { public var minuteOfDay: Int; public var profile: String; public init(minuteOfDay:profile:) }`
  - `public enum ProfileSchedule { public static func active(atMinuteOfDay minute: Int, rules: [ProfileRule]) -> String? }` — latest rule at/before `minute`; if none, the last rule of the day (wrap-around); nil for empty rules.
  - `DashboardModule.scheduleRules: [ProfileRule]` (key `"profile.schedule"`, JSON, default empty = feature off) + a 60 s timer active only while rules exist.

- [ ] **Step 1: Write the failing checks**

```swift
// MARK: - QuoteBook + ProfileSchedule

expect(!QuoteBook.quotes.isEmpty, "quotes bundled")
expect(QuoteBook.quote(dayOfYear: 1) == QuoteBook.quote(dayOfYear: 1), "stable per day")
expect(QuoteBook.quote(dayOfYear: 400) == QuoteBook.quotes[400 % QuoteBook.quotes.count], "wraps")

let rules = [
    ProfileRule(minuteOfDay: 9 * 60, profile: "Work"),
    ProfileRule(minuteOfDay: 18 * 60, profile: "Default"),
]
expect(ProfileSchedule.active(atMinuteOfDay: 10 * 60, rules: rules) == "Work", "10:00 → Work")
expect(ProfileSchedule.active(atMinuteOfDay: 20 * 60, rules: rules) == "Default", "20:00 → Default")
expect(ProfileSchedule.active(atMinuteOfDay: 3 * 60, rules: rules) == "Default", "03:00 wraps to yesterday's last rule")
expect(ProfileSchedule.active(atMinuteOfDay: 600, rules: []) == nil, "no rules → nil")
```

- [ ] **Step 2: Run to verify failure**

Run: `swift run NotchDeckChecks` — compile error.

- [ ] **Step 3: Implement**

`QuoteBook.swift`:

```swift
public enum QuoteBook {
    public static let quotes: [String] = [
        "Simplicity is the ultimate sophistication. — Leonardo da Vinci",
        "The best way to predict the future is to invent it. — Alan Kay",
        "Make it work, make it right, make it fast. — Kent Beck",
        "Focus is saying no to a thousand things. — Steve Jobs",
        "Amateurs sit and wait for inspiration; the rest of us get up and go to work. — Stephen King",
        "What gets measured gets managed. — Peter Drucker",
        "Deep work is the superpower of the 21st century. — Cal Newport",
        "Perfection is achieved when there is nothing left to take away. — Antoine de Saint-Exupéry",
        "You do not rise to the level of your goals; you fall to the level of your systems. — James Clear",
        "The impediment to action advances action. — Marcus Aurelius",
        "Little by little, one travels far. — J.R.R. Tolkien",
        "Well begun is half done. — Aristotle",
    ]

    public static func quote(dayOfYear: Int) -> String {
        quotes[((dayOfYear % quotes.count) + quotes.count) % quotes.count]
    }
}
```

`ProfileSchedule.swift`:

```swift
import Foundation

public struct ProfileRule: Codable, Equatable, Sendable {
    public var minuteOfDay: Int
    public var profile: String

    public init(minuteOfDay: Int, profile: String) {
        self.minuteOfDay = minuteOfDay
        self.profile = profile
    }
}

public enum ProfileSchedule {
    /// Latest rule at/before `minute`; wraps to the day's last rule overnight.
    public static func active(atMinuteOfDay minute: Int, rules: [ProfileRule]) -> String? {
        guard !rules.isEmpty else { return nil }
        let sorted = rules.sorted { $0.minuteOfDay < $1.minuteOfDay }
        return (sorted.last { $0.minuteOfDay <= minute } ?? sorted.last)?.profile
    }
}
```

- [ ] **Step 4: Quotes widget + schedule engine in `DashboardModule`**

Add a quotes widget (place it in the second `GridRow` by replacing the second `LauncherWidget` — the "Actions" one moves to the first row replacing `PomodoroMiniWidget`? **No** — keep it simple and faithful: swap `DayProgressWidget` (now redundant with the Task 15 module) for the quote):

In `DashboardPanelView`, replace `DayProgressWidget()` with `QuoteWidget()` and add:

```swift
private struct QuoteWidget: View {
    var body: some View {
        WidgetCell(title: "Quote", titleIcon: "quote.opening") {
            let day = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 1
            Text(QuoteBook.quote(dayOfYear: day))
                .font(.system(size: 10))
                .italic()
                .foregroundStyle(.secondary)
                .frame(maxHeight: .infinity, alignment: .center)
        }
    }
}
```

Time-based switching — add to `DashboardModule`:

```swift
@Published var scheduleRules: [ProfileRule] {
    didSet {
        if let data = try? JSONEncoder().encode(scheduleRules) {
            UserDefaults.standard.set(data, forKey: "profile.schedule")
        }
        restartScheduleTimer()
    }
}
private var scheduleTimer: Timer?
```

init:

```swift
scheduleRules = (UserDefaults.standard.data(forKey: "profile.schedule"))
    .flatMap { try? JSONDecoder().decode([ProfileRule].self, from: $0) } ?? []
```

and:

```swift
private func restartScheduleTimer() {
    scheduleTimer?.invalidate()
    scheduleTimer = nil
    guard !scheduleRules.isEmpty else { return }
    scheduleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let self = DashboardModuleShared.instance else { return }
                let parts = Calendar.current.dateComponents([.hour, .minute], from: Date())
                let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                if let wanted = ProfileSchedule.active(atMinuteOfDay: minute, rules: self.scheduleRules),
                   wanted != self.activeProfile {
                    self.switchProfile(to: wanted)
                }
            }
        }
    }
}
```

Add the shared holder (same pattern as `DropModuleShared`):

```swift
@MainActor
enum DashboardModuleShared {
    weak static var instance: DashboardModule?
}
```

set `DashboardModuleShared.instance = self` and `restartScheduleTimer()` in `activate()`; invalidate the timer in `deactivate()`.

Settings UI — add to a `settingsView()` on `DashboardModule`:

```swift
func settingsView() -> AnyView {
    AnyView(
        Section("Dashboard profiles") {
            ForEach(Self.profiles, id: \.self) { profile in
                HStack {
                    Text(profile)
                    Spacer()
                    let rule = scheduleRules.first { $0.profile == profile }
                    Stepper(
                        rule.map { String(format: "at %02d:%02d", $0.minuteOfDay / 60, $0.minuteOfDay % 60) } ?? "no schedule",
                        onIncrement: { adjustRule(profile, by: 30) },
                        onDecrement: { adjustRule(profile, by: -30) }
                    )
                }
            }
        }
    )
}

private func adjustRule(_ profile: String, by minutes: Int) {
    if let index = scheduleRules.firstIndex(where: { $0.profile == profile }) {
        var rule = scheduleRules[index]
        let next = rule.minuteOfDay + minutes
        if next < 0 { scheduleRules.remove(at: index); return } // stepping below 0 removes
        rule.minuteOfDay = min(next, 23 * 60 + 30)
        scheduleRules[index] = rule
    } else {
        scheduleRules.append(ProfileRule(minuteOfDay: max(0, minutes), profile: profile))
    }
}
```

- [ ] **Step 5: Run checks + build + commit**

`swift run NotchDeckChecks` — pass. `swift build` — pass.

```bash
git add -A && git commit -m "feat: quote widget + time-based profile switching"
```

---

### Task 20: Dashboard — mirror widget (camera)

MacNotch's dashboard has a camera "mirror" widget. Off by default; starts the camera only while visible **and** enabled.

**Files:**
- Create: `Sources/NotchDeckKit/Modules/Dashboard/MirrorWidget.swift`
- Modify: `Sources/NotchDeckKit/Modules/Dashboard/DashboardModule.swift`
- Modify: `Resources/Info.plist`

**Interfaces:**
- Produces: `struct MirrorWidget: View` (replaces the second-row `LauncherWidget(range: 5..<10)` slot only when defaults key `"dashboard.mirror"` is true — the Actions launcher stays otherwise); `SettingsStore` untouched (widget has its own toggle in the dashboard settings section from Task 19).

- [ ] **Step 1: Info.plist**

Add to `Resources/Info.plist` before `</dict>`:

```xml
<key>NSCameraUsageDescription</key>
<string>NotchDeck shows a quick mirror widget on the dashboard.</string>
```

- [ ] **Step 2: Implement `MirrorWidget.swift`**

```swift
import AVFoundation
import SwiftUI

/// Camera preview that only runs while the widget is on screen.
@MainActor
final class MirrorController: ObservableObject {
    @Published var denied = false
    let session = AVCaptureSession()

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        granted ? self.configureAndRun() : (self.denied = true)
                    }
                }
            }
        default:
            denied = true
        }
    }

    func stop() {
        let session = session
        Task.detached { session.stopRunning() }
    }

    private func configureAndRun() {
        if session.inputs.isEmpty,
           let camera = AVCaptureDevice.default(for: .video),
           let input = try? AVCaptureDeviceInput(device: camera),
           session.canAddInput(input) {
            session.beginConfiguration()
            session.sessionPreset = .low
            session.addInput(input)
            session.commitConfiguration()
        }
        let session = session
        Task.detached { session.startRunning() }
    }
}

struct MirrorWidget: View {
    @StateObject private var controller = MirrorController()

    var body: some View {
        WidgetCell(title: "Mirror", titleIcon: "web.camera") {
            Group {
                if controller.denied {
                    Text("Camera access is off")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                } else {
                    CameraPreview(session: controller.session)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .scaleEffect(x: -1) // mirror like a real mirror
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { controller.start() }
        .onDisappear { controller.stop() }
    }
}

private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
```

`WidgetCell` currently lives in `DashboardModule.swift` as `private struct WidgetCell` — change that declaration to `struct WidgetCell` (internal) so this file can use it.

- [ ] **Step 3: Slot it in**

In `DashboardPanelView` second `GridRow`, replace the fixed `LauncherWidget(module: module, range: 5..<10, title: "Actions")` with:

```swift
if UserDefaults.standard.bool(forKey: "dashboard.mirror") {
    MirrorWidget()
} else {
    LauncherWidget(module: module, range: 5..<10, title: "Actions")
}
```

and add the toggle to `DashboardModule.settingsView()`'s section (Task 19):

```swift
Toggle("Mirror widget (camera) replaces Actions", isOn: Binding(
    get: { UserDefaults.standard.bool(forKey: "dashboard.mirror") },
    set: { UserDefaults.standard.set($0, forKey: "dashboard.mirror") }
))
```

- [ ] **Step 4: Build + manual verify + commit**

`swift build` — pass. Manual: enable mirror in Settings, open dashboard — camera prompt, then live mirrored preview; collapse the notch — camera indicator light turns off (session stopped).

```bash
git add -A && git commit -m "feat: camera mirror dashboard widget (opt-in)"
```

---

### Task 21: Settings — module reorder + default module

MacNotch: "Reorder them, set which module opens by default."

**Files:**
- Modify: `Sources/NotchDeckKit/Modules/NotchModule.swift`
- Modify: `Sources/NotchDeckKit/Settings/SettingsWindow.swift`
- Modify: `Sources/NotchDeckKit/Shell/NotchShellController.swift`
- Test: `Sources/NotchDeckChecks/main.swift`

**Interfaces:**
- Produces:
  - `public enum ModuleOrder { public static func apply(order: [String], to ids: [String]) -> [String] }` — sorts `ids` by position in `order`; ids missing from `order` keep relative position at the end. Pure.
  - `ModuleRegistry.moveModule(_ id: String, by delta: Int)` persisting to key `"module.order"`; `modules` returns registered modules in saved order; `@Published private(set) var orderVersion = 0` bumped on each move (so SwiftUI lists refresh).
  - `SettingsStore.defaultModuleID: String?` (key `"module.default"`).

- [ ] **Step 1: Write the failing checks**

```swift
// MARK: - ModuleOrder

expect(ModuleOrder.apply(order: ["b", "a"], to: ["a", "b", "c"]) == ["b", "a", "c"],
       "saved order wins; unknown ids append")
expect(ModuleOrder.apply(order: [], to: ["a", "b"]) == ["a", "b"], "no saved order → unchanged")
expect(ModuleOrder.apply(order: ["x"], to: ["a"]) == ["a"], "stale ids ignored")
```

- [ ] **Step 2: Run to verify failure**

Run: `swift run NotchDeckChecks` — compile error.

- [ ] **Step 3: Implement**

In `NotchModule.swift` add:

```swift
public enum ModuleOrder {
    public static func apply(order: [String], to ids: [String]) -> [String] {
        let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return ids.enumerated().sorted {
            let a = position[$0.element] ?? order.count + $0.offset
            let b = position[$1.element] ?? order.count + $1.offset
            return a < b
        }.map(\.element)
    }
}
```

In `ModuleRegistry`:

```swift
@Published private(set) var orderVersion = 0

func register(_ newModules: [any NotchModule]) {
    let saved = UserDefaults.standard.stringArray(forKey: "module.order") ?? []
    let orderedIDs = ModuleOrder.apply(order: saved, to: newModules.map(\.id))
    modules = orderedIDs.compactMap { id in newModules.first { $0.id == id } }
    for module in modules where settings.isModuleEnabled(module.id) {
        module.activate()
        enabledIDs.insert(module.id)
    }
}

func moveModule(_ id: String, by delta: Int) {
    guard let index = modules.firstIndex(where: { $0.id == id }) else { return }
    let target = index + delta
    guard modules.indices.contains(target) else { return }
    modules.swapAt(index, target)
    UserDefaults.standard.set(modules.map(\.id), forKey: "module.order")
    orderVersion += 1
}
```

In `SettingsStore`:

```swift
@Published var defaultModuleID: String? {
    didSet { defaults.set(defaultModuleID, forKey: "module.default") }
}
```

init: `defaultModuleID = defaults.string(forKey: "module.default")`

In `NotchShellController.addPanel`, after creating the vm:

```swift
vm.selectedModuleID = settings.defaultModuleID
```

- [ ] **Step 4: Settings UI**

In `SettingsWindow.swift` Modules section, replace the plain toggle row with toggle + arrows:

```swift
ForEach(registry.modules, id: \.id) { module in
    HStack {
        Toggle(isOn: Binding(
            get: { registry.enabledIDs.contains(module.id) },
            set: { registry.setEnabled(module.id, $0) }
        )) {
            Label(module.name, systemImage: module.icon)
        }
        Spacer()
        Button { registry.moveModule(module.id, by: -1) } label: {
            Image(systemName: "chevron.up")
        }.buttonStyle(.borderless)
        Button { registry.moveModule(module.id, by: 1) } label: {
            Image(systemName: "chevron.down")
        }.buttonStyle(.borderless)
    }
}
Picker("Open by default", selection: Binding(
    get: { settings.defaultModuleID ?? "" },
    set: { settings.defaultModuleID = $0.isEmpty ? nil : $0 }
)) {
    Text("First module").tag("")
    ForEach(registry.panelModules, id: \.id) { Text($0.name).tag($0.id) }
}
```

- [ ] **Step 5: Run checks + build + commit**

`swift run NotchDeckChecks` — pass. `swift build` — pass. Manual: move Media to the top — dock order updates after reopening the panel; set Calendar as default — expanding a fresh panel opens Calendar.

```bash
git add -A && git commit -m "feat: module reordering + default module setting"
```

---

## Final Validation

- [ ] `swift run NotchDeckChecks` — zero failures.
- [ ] `swift build 2>&1 | grep -c warning` — no new warnings vs. `main`.
- [ ] `bash scripts/bundle.sh && open dist/NotchDeck.app` — full manual sweep:
  1. Snap: drag a window to the top → tiles → snap left half.
  2. ⇧⌘-recorded shortcut toggles the notch; snooze hides/wakes.
  3. Screenshot with capture-hiding off → notch absent from the image.
  4. Drag a file over the notch → tile grid; hover Expand → second row; drop on Zip/Unzip/Trash.
  5. Strip rotates Pomodoro ↔ calendar ↔ Bluetooth every ~6 s; media hover shows transport.
  6. Pomodoro finish → sound + "Timer done" pill.
  7. Calendar search filters; overdue reminders listed.
  8. Task delete → appears in Trash filter → Restore brings it back.
  9. Day Progress module shows today's events on the timeline with bedtime marker.
  10. Screen Time module: donut, categories, ranked bars, switch count badge.
  11. Notifications: dismiss one, Clear all.
  12. Notes: two notes, switch, delete.
  13. Dashboard: quote shows; mirror toggle works; profile switches at a scheduled time.
  14. Settings: reorder modules, set default module.
- [ ] Update `README.md` Features section to cover Phase 5 (snap zones, shortcuts, capture hiding, drop grid, rotation, module deepenings) and the new permissions (Accessibility for Snap Zones, Camera for Mirror).
- [ ] Final commit: `git add -A && git commit -m "docs: phase 5 README update"`

## Known deltas vs. MacNotch that remain after this plan

Kept out deliberately (see Out of Scope): licensing/Setapp/Sparkle/telemetry/support module, notification reply and true NC clearing, real audio spectrum, per-display picker, Cursor-Agent monitoring (Claude Code only), richer snap previews via Screen Recording, drop-grid configurability (custom order/folders/dividers/width), Focus-driven profile switching (time-based only), paginated launcher sets, session-lock collapsed view, app-update live-activity source, and the quick-toggle "Persist Never Sleep with Launch at Login" option.
