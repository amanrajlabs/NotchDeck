# NotchDeck Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Working native notch app: shell + media + HUD + drop actions + bluetooth battery + calendar + settings, packaged as a signed `.app`.

**Architecture:** Single LSUIElement SwiftUI/AppKit app. A non-activating NSPanel sits over the notch; a `NotchViewModel` state machine drives collapsed/expanded UI; features are `NotchModule` implementations that only hold observers while enabled/visible.

**Tech Stack:** Swift 6 (SPM, CLT-only — no Xcode), SwiftUI + AppKit, ScriptingBridge (AppleEvents), CoreAudio, IOKit, EventKit, UserNotifications.

## Global Constraints

- macOS 14+ deployment floor (`platforms: [.macOS(.v14)]`), dev machine is macOS 26.5.
- No third-party dependencies. No private frameworks in Phase 1 (MediaRemote deferred).
- Build must work with Command Line Tools only: `swift build` + `scripts/bundle.sh` → `dist/NotchDeck.app`, ad-hoc codesigned with entitlements-free Info.plist usage strings.
- Efficiency: no timers/observers while a module is disabled; collapsed idle CPU ≈ 0%.
- Swift 6 strict concurrency: UI types `@MainActor`.

## File Structure

```
Package.swift
scripts/bundle.sh                     # build + wrap .app + codesign
Resources/Info.plist                  # LSUIElement, usage strings
Sources/NotchDeck/
  App/main.swift                      # NSApplication bootstrap, AppDelegate
  App/StatusItemController.swift      # menu bar icon (settings/quit)
  Shell/NotchGeometry.swift           # pure math: notch rect per screen (TESTED)
  Shell/NotchPanel.swift              # NSPanel subclass
  Shell/NotchViewModel.swift          # state machine collapsed/expanded
  Shell/NotchRootView.swift           # SwiftUI shell: shape, hover, tabs, live strip
  Shell/NotchShape.swift              # rounded-corner notch shape
  Modules/NotchModule.swift           # protocol + ModuleRegistry
  Modules/Media/MediaController.swift # ScriptingBridge players (TESTED: state mapping)
  Modules/Media/MediaViews.swift
  Modules/HUD/HUDController.swift     # CoreAudio volume + brightness watchers
  Modules/HUD/HUDViews.swift
  Modules/Drop/DropActions.swift      # zip/convert/move/copy/airdrop ops (TESTED)
  Modules/Drop/DropViews.swift
  Modules/Bluetooth/BTBattery.swift   # IORegistry scan (TESTED: payload parsing)
  Modules/Bluetooth/BTViews.swift
  Modules/Calendar/CalendarSource.swift # EventKit + meeting detection (TESTED)
  Modules/Calendar/CalendarViews.swift
  Settings/SettingsStore.swift        # UserDefaults-backed toggles
  Settings/SettingsWindow.swift
Tests/NotchDeckTests/                 # geometry, drop ops, meeting URLs, BT parsing
```

---

### Task 1: Scaffold + bundle pipeline

**Files:** Create `Package.swift`, `Resources/Info.plist`, `scripts/bundle.sh`, `Sources/NotchDeck/App/main.swift`, `App/StatusItemController.swift`.

**Interfaces:** Produces `AppDelegate` with `applicationDidFinishLaunching` wiring; `bundle.sh` producing `dist/NotchDeck.app`.

- [ ] Package.swift: executable target `NotchDeck`, test target, `.macOS(.v14)`.
- [ ] Info.plist: `LSUIElement=true`, `NSCalendarsFullAccessUsageDescription`, `NSAppleEventsUsageDescription`, `NSBluetoothAlwaysUsageDescription`, bundle id `io.notchdeck.app`.
- [ ] bundle.sh: `swift build -c release`, assemble `dist/NotchDeck.app/Contents/{MacOS,Resources}`, copy plist+binary, `codesign --force --deep -s - dist/NotchDeck.app`.
- [ ] main.swift: `NSApplication` + AppDelegate, `.accessory` activation policy, status item with menu (Settings…, Quit).
- [ ] Verify: `bash scripts/bundle.sh && open dist/NotchDeck.app` → status item appears. Commit.

### Task 2: Notch geometry (TDD)

**Files:** Create `Shell/NotchGeometry.swift`, `Tests/NotchDeckTests/NotchGeometryTests.swift`.

**Interfaces:** Produces `NotchGeometry.notchRect(screenFrame:safeTopInset:auxTopLeftWidth:auxTopRightWidth:) -> CGRect` and `expandedFrame(for:size:) -> CGRect` (pure functions; window code feeds NSScreen values in).

- [ ] Failing tests: notched screen (aux areas set) → centered rect of width `screenW - left - right`, height = safeTopInset; notchless → simulated 200×32 centered; expanded frame centered under top edge.
- [ ] Implement; tests pass; commit.

### Task 3: Notch shell

**Files:** Create `Shell/NotchPanel.swift`, `Shell/NotchViewModel.swift`, `Shell/NotchShape.swift`, `Shell/NotchRootView.swift`. Modify `main.swift`.

**Interfaces:** Produces `@MainActor final class NotchViewModel: ObservableObject` with `@Published var state: NotchState` (`.collapsed`/`.expanded`), `expandedSize: CGSize`, `func setHover(_:)`, `func toggle()`. `NotchPanel` is non-activating, `.statusBar` level, all-spaces + fullScreenAuxiliary, transparent.

Key panel config:

```swift
let panel = NotchPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
panel.level = .statusBar
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
panel.isOpaque = false; panel.backgroundColor = .clear
panel.hasShadow = false; panel.isMovable = false
panel.hidesOnDeactivate = false
```

Window is sized to the *expanded* frame always; SwiftUI draws collapsed/expanded content top-aligned so the tiny collapsed shape hugs the notch, avoiding frame thrash. Hover (onHover + small delay) expands; mouse-exit collapses; spring `.snappy` animation.

- [ ] Implement, wire into AppDelegate for `NSScreen.main`. Verify visually: hover over notch → black panel expands with rounded bottom corners. Commit.

### Task 4: Module framework + settings

**Files:** Create `Modules/NotchModule.swift`, `Settings/SettingsStore.swift`, `Settings/SettingsWindow.swift`. Modify `NotchRootView.swift`, `StatusItemController.swift`.

**Interfaces:** Produces:

```swift
@MainActor protocol NotchModule: AnyObject, Identifiable {
    var id: String { get }; var name: String { get }; var icon: String { get }
    var isEnabled: Bool { get }
    func activate(); func deactivate()
    @ViewBuilder func panelView() -> AnyView
    @ViewBuilder func liveActivityView() -> AnyView?   // nil when nothing live
    @ViewBuilder func settingsView() -> AnyView
}
@MainActor final class ModuleRegistry: ObservableObject { var modules: [any NotchModule]; func setEnabled(_ id: String, _ on: Bool) }
final class SettingsStore { @AppStorage-backed bools per module + hudSuppressSystem + launchAtLogin }
```

Expanded UI = horizontal tab bar of enabled modules + content area; collapsed strip composes non-nil `liveActivityView()`s (max 2, leading/trailing of notch). Settings window lists General + per-module toggles; `SMAppService.mainApp` for launch at login.

- [ ] Implement with a placeholder "Dashboard" module; verify toggles persist; commit.

### Task 5: Media module

**Files:** Create `Modules/Media/MediaController.swift`, `Modules/Media/MediaViews.swift`.

**Interfaces:** Produces `MediaController: ObservableObject` with `@Published var track: TrackInfo?` (`title, artist, artwork: NSImage?, duration, position, isPlaying, player: PlayerApp`), `play/pause/next/previous/seek(to:)`. Consumes ModuleRegistry from Task 4.

Implementation: no ScriptingBridge codegen (needs Xcode headers) — send AppleScript via `NSAppleScript` wrapped in a tiny runner (`AppleScriptRunner.run(_:) -> NSAppleEventDescriptor?`) executed off-main, targeting whichever of Spotify (`com.spotify.client`) / Music (`com.apple.Music`) is running (checked via `NSRunningApplication`, event-driven via `NSWorkspace.didLaunch/didTerminate` notifications). Poll position 1 Hz **only while panel expanded or live activity visible and playing**; also observe `com.spotify.client.PlaybackStateChanged` / `com.apple.Music.playerInfo` DistributedNotifications for instant updates (these carry track metadata — primary source; AppleScript fills artwork/position). Artwork: Spotify artwork URL → URLSession; Music artwork raw data.

Testable pure part: mapping DistributedNotification userInfo → `TrackInfo` (`MediaStateMapper.trackInfo(from:playerBundleID:)`).

- [ ] Test mapper with fixture dictionaries; implement controller + views (art, animated 4-bar equalizer while playing, scrubber slider, prev/play/next). Live activity: 24×24 art + eq bars. Verify with Music.app playing. Commit.

### Task 6: HUD module

**Files:** Create `Modules/HUD/HUDController.swift`, `Modules/HUD/HUDViews.swift`.

**Interfaces:** Produces `HUDController` publishing `hudEvent: HUDEvent?` (`kind: .volume/.brightness, level: Float, muted: Bool`); root view overlays a transient capsule beside the notch for 1.2 s on event.

Volume: `AudioObjectAddPropertyListenerBlock` on default output device for `kAudioDevicePropertyVolumeScalar`/`Mute` (re-resolve device on `kAudioHardwarePropertyDefaultOutputDevice` change). Brightness: `DisplayServicesGetBrightness` via `dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices")` — read-only poll at 2 Hz **only while module enabled**, diff-triggered; if symbol missing, brightness HUD silently unavailable. Optional system-bezel suppression (`hudSuppressSystem` default false): launchctl unload of OSDUIHelper is fragile on modern macOS — implement as best-effort `killall OSDUIHelper` repeater documented in settings as experimental.

- [ ] Implement; verify volume keys show notch HUD. Commit.

### Task 7: Drop actions (TDD on file ops)

**Files:** Create `Modules/Drop/DropActions.swift`, `Modules/Drop/DropViews.swift`, `Tests/NotchDeckTests/DropActionsTests.swift`. Modify `NotchRootView` (drag detection → auto-expand into drop grid).

**Interfaces:** Produces `enum DropAction { airdrop, zip, convertImage(ImageFormat), moveToFolder, copyToFolder, openWith }` and `DropActionRunner` with `static func zip(_ urls: [URL]) throws -> URL`, `static func convert(_ url: URL, to: ImageFormat) throws -> URL` (ImageIO), `static func move/copy(_ urls: [URL], to dir: URL) throws`; AirDrop via `NSSharingService(named: .sendViaAirDrop)`; openWith via `NSWorkspace.shared.urlsForApplications(toOpen:)` menu.

- [ ] Failing tests: zip creates archive containing file; convert png→jpeg produces decodable jpeg; move relocates file. Implement; pass; wire `onDrop(of: [.fileURL])` on root view (dragging over collapsed notch expands to grid). Verify by dragging a file. Commit.

### Task 8: Bluetooth battery (TDD on parsing)

**Files:** Create `Modules/Bluetooth/BTBattery.swift`, `Modules/Bluetooth/BTViews.swift`, `Tests/NotchDeckTests/BTBatteryTests.swift`.

**Interfaces:** Produces `BTDevice { name, kind: .airpods/.mouse/.keyboard/.headphones/.controller/.other, batteries: [BatterySlot] }`, `BatterySlot { label: String /* "L","R","Case","" */, percent: Int }`; `BTBatteryScanner.parse(properties: [String: Any]) -> BTDevice?` (pure, tested) + `scan()` walking IORegistry (`IOServiceMatching("AppleDeviceManagementHIDEventService")` + `IOBluetoothDevice.pairedDevices`) refreshed on panel expand + every 60 s while live activity enabled; ≤20% triggers one `UNUserNotificationCenter` alert per device/session.

- [ ] Failing tests: AirPods props dict (`BatteryPercentLeft/Right/Case`, `DeviceName`) → 3 slots; mouse dict (`BatteryPercent`) → 1 slot; missing keys → nil. Implement; pass; views (device list with SF Symbols + percent rings). Verify with paired devices. Commit.

### Task 9: Calendar module (TDD on meeting detection)

**Files:** Create `Modules/Calendar/CalendarSource.swift`, `Modules/Calendar/CalendarViews.swift`, `Tests/NotchDeckTests/MeetingDetectorTests.swift`.

**Interfaces:** Produces `CalendarSource: ObservableObject` with `@Published var upcoming: [EventItem]` (`title, start, end, meetingURL: URL?, calendarColor`), `requestAccess()`; `MeetingDetector.url(in texts: [String?]) -> URL?` (pure, tested — zoom.us, meet.google.com, teams.microsoft.com, webex.com patterns). EventKit `EKEventStore`, refresh on `.EKEventStoreChanged` + 30 s countdown tick only while live activity visible. Live activity: "Standup in 12m" pill; expanded: today list + Join button.

- [ ] Failing tests for detector across the 4 providers + none; implement; wire EventKit with denied-state CTA view; verify. Commit.

### Task 10: Polish + verify

**Files:** Modify root view (live strip layout), Create `README.md`.

- [ ] Compose live activities (media left of notch, calendar/HUD right), cap widths to aux areas.
- [ ] `swift test` full pass; `bash scripts/bundle.sh`; launch; measure `ps -o %cpu,rss` idle collapsed (expect ~0.0 %CPU).
- [ ] README: features, build, permissions. Final commit.

## Self-Review

Spec coverage: shell ✓(T3) media ✓(T5) HUD ✓(T6) drop ✓(T7) BT ✓(T8) calendar ✓(T9) settings/launch-at-login ✓(T4) efficiency verification ✓(T10). Notchless/external displays: geometry fallback in T2 (full multi-display rendering is Phase 3 per spec). Types cross-checked: `NotchModule`, `TrackInfo`, `BTDevice`, `EventItem` names consistent across tasks.
