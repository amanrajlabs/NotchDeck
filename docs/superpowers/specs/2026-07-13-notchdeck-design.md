# NotchDeck — Design Spec

Native macOS replica of MacNotch (macnotch.io): a productivity hub living in the MacBook notch.
Approved 2026-07-13. Approach: native Swift from scratch. Delivery: core first (Phase 1), then iterate.

## Goals

- Match MacNotch's feature set over three phases; match its efficiency (idle ~0% CPU, <100 MB RAM).
- Run on the user's 14" MacBook Pro, macOS 26.x; support notchless/external displays via simulated notch.
- Build without full Xcode: Swift 6 + SPM executable wrapped into a `.app` bundle, ad-hoc signed.

## Architecture

- **Process**: single LSUIElement app (no Dock icon) with a menu-bar status item (open settings, quit).
- **Notch window**: borderless, non-activating `NSPanel`, `.statusBar` level, `canJoinAllSpaces` +
  `fullScreenAuxiliary`, positioned top-center of the screen. Collapsed size = physical notch rect
  (derived from `NSScreen.safeAreaInsets` / `auxiliaryTopLeftArea`/`auxiliaryTopRightArea`);
  fallback simulated notch (200×32) on displays without one.
- **State machine**: `collapsed → hoverPeek → expanded` driven by `NSTrackingArea` + click; spring
  animations in SwiftUI. Expanded panel hosts a tab/dashboard of module views.
- **Module system**: `NotchModule` protocol — `id`, `name`, optional `liveActivityView` (collapsed
  strip), `panelView` (expanded), `settingsView`, `activate()/deactivate()`. Modules are toggled in
  Settings; inactive modules hold no timers/observers.
- **Efficiency rules**: event-driven observers only; timers exist only while their view is visible
  (`TimelineView` / invalidated `Timer`s on collapse); no polling loops while collapsed except
  1-per-30s calendar countdown refresh when a live activity is showing.
- **Persistence**: `UserDefaults` via a small `Settings` store (`@AppStorage`-backed).
- **Permissions**: Info.plist usage strings for Calendars, Reminders (P2), Bluetooth, AppleEvents
  (media control), Notifications. Ad-hoc codesign so TCC grants persist.

## Phase 1 modules

1. **Media** — Spotify + Apple Music via ScriptingBridge/AppleEvents: track, artist, album art,
   play/pause/prev/next, scrubbing, animated equalizer bars while playing. Collapsed live activity:
   mini art + bars. Browser/system-wide playback (private MediaRemote) deferred — documented risk.
2. **HUD** — volume changes via CoreAudio property listeners; brightness via DisplayServices poll-on
   -key-event. Renders a transient HUD in/beside the notch. Optional (off by default) suppression of
   the system bezel via OSDUIHelper stop — documented as hacky.
3. **Drop actions** — notch accepts file drags; expanded drop grid: AirDrop (`NSSharingService`),
   Zip (`ditto`), Convert image (ImageIO → png/jpeg/heic), Move/Copy to chosen folder, Open with….
4. **Bluetooth battery** — IOKit/IORegistry (`BatteryPercent`, `BatteryPercentLeft/Right/Case`) +
   IOBluetooth device names; low-battery (≤20%) local notification once per device per session.
5. **Calendar live activity** — EventKit next-event countdown in collapsed strip; expanded list of
   today's events; meeting-URL detection (zoom/meet/teams/webex) with Join button.
6. **Settings window** — standard SwiftUI window: General (launch at login via SMAppService, display
   choice, expansion behavior), per-module toggles, per-module panes.

## Phase 2 (next)

Widget dashboard grid (weather via Open-Meteo, quick toggles: Dark Mode/True Tone/Night Shift/Keep
Awake/Hide Desktop Icons, app launchers, profiles Work/Personal/Focus), system monitor (CPU/RAM/
storage), Pomodoro, Tasks (EventKit Reminders), quick notes.

## Phase 3

Notifications strip, translation (OpenAI/Ollama), GitHub/GitLab/Bitbucket PR views, Claude Code
session monitor, screen-time-style usage donut, multi-display rendering.

## Error handling

- Media: app-not-running → module shows idle state; AppleEvent permission denied → inline prompt.
- EventKit denied → module shows "grant access" call-to-action opening System Settings.
- IORegistry keys missing (OS change) → device listed without percentage, no crash.
- All module failures are isolated; the shell never dies with a module.

## Testing / verification

- `swift test` for pure logic: notch geometry math, meeting-URL detection, drop-action file ops
  (zip/convert on temp files), battery-payload parsing.
- Manual/scripted verification: build bundle, launch, screenshot, check CPU/RAM via `ps`.

## Risks (accepted)

- AirPods battery keys are undocumented; may vary by firmware.
- System HUD suppression is unsupported by Apple; opt-in only.
- ScriptingBridge needs Automation TCC prompts per target app.
- Browser media (MediaRemote adapter) intentionally out of Phase 1.
