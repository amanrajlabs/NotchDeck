# NotchDeck

A native macOS notch productivity hub — a from-scratch replica of MacNotch
(macnotch.io). Swift 6 + SwiftUI, no dependencies, built with only Command
Line Tools (no Xcode required).

## Features (Phase 1)

- **Notch shell** — hover or click the notch to expand a dashboard; collapses
  back to the exact notch footprint. Works on notchless displays with a
  simulated notch.
- **Media** — Spotify, Apple Music, and anything else (browsers/YouTube, VLC, …)
  via the system now-playing session: album art, animated equalizer, scrub,
  play/pause/next/previous. Now-playing live activity beside the notch.
- **Volume/brightness HUD** — level changes render beside the notch. Optional
  experimental suppression of Apple's bezel (Settings).
- **Drop actions** — drag files onto the notch: AirDrop, Zip, PNG/JPEG
  convert, Move/Copy to folder, Open With.
- **Bluetooth battery** — AirPods (L/R/case) and peripherals with battery
  rings; low-battery notification at ≤20%.
- **Calendar** — next-event countdown pill, today's events, meeting-link
  detection (Zoom/Meet/Teams/Webex) with a Join button.
- **Notifications** — recent Notification Center items grouped in the panel
  (reads the system store; needs Full Disk Access, one-click CTA otherwise).
- **Translation** — OpenAI or local Ollama, 10 target languages.
- **Pull Requests** — open PRs/MRs from GitHub, GitLab, and Bitbucket Cloud
  (tokens in Settings), authored + review-requested, newest first.
- **Claude Code monitor** — recent sessions with live-activity dot, model,
  and token usage parsed from ~/.claude/projects.
- **Screen time** — self-tracked app usage donut on the dashboard (event-
  driven, no polling).
- **Settings** — menu-bar icon → Settings: per-module toggles, launch at
  login, show on all displays.

Browser/system media uses the vendored [mediaremote-adapter](Vendor/mediaremote-adapter)
(BSD-3) hosted by /usr/bin/perl to pass the MediaRemote entitlement gate.

## Features (Phase 5 — MacNotch parity)

- **Window Snap Zones** — drag a window toward the top of the screen and a
  tile strip drops from the notch (halves, thirds, quarters, maximize);
  release over a tile to snap. Configurable layouts. Needs Accessibility.
- **Keyboard shortcuts + snooze** — record global hotkeys (toggle notch,
  next/previous module, snooze/wake); snooze hides the notch for a set
  duration, also from the menu bar.
- **Screen-capture hiding** — a General toggle removes the notch strip from
  screenshots, recordings, and screen sharing.
- **Notch nudge** — vertical alignment slider for displays where the notch
  sits below the menu bar.
- **Drop-to-act grid** — dragging files over the notch opens an action-tile
  grid (Shelf, AirDrop, Zip, Unzip, convert, Move/Copy, Open With, Music,
  Trash/Eject, iCloud Drive) with an Expand row.
- **Rotating live activities** — the collapsed strip cycles media, timers,
  calendar, Bluetooth, and an unread-notifications glance; HUD interrupts win.
- **Media** — optional hover-reveal transport in the strip; Bars or Spectrum
  visualization.
- **Pomodoro** — completion sound + a "Timer done" pill.
- **Calendar** — search events by title; overdue reminders section.
- **Tasks** — delete to a 30-day Trash with restore.
- **Day Progress** — a timeline of today's events with a bedtime marker.
- **Screen Time** — dedicated module: category charts, ranked apps, and
  app-switch counts.
- **Notifications** — per-item dismiss and Clear All (local).
- **Notes** — multiple notes with a sidebar; legacy scratchpad migrates in.
- **Dashboard** — daily quote widget; time-based profile switching; an
  opt-in camera "mirror" widget (needs Camera).
- **Module management** — reorder modules and pick which opens by default.

Planned features from Phases 2–3 (widget dashboard, system monitor, Pomodoro,
tasks, notes, notifications, translation, PRs, Claude monitor) all shipped.
See `docs/superpowers/specs/` and `docs/superpowers/plans/`.

## Build & run

```sh
bash scripts/bundle.sh        # release build → dist/NotchDeck.app
open dist/NotchDeck.app
```

Checks (no XCTest under CLT, so tests are a plain executable):

```sh
swift run NotchDeckChecks
```

## Permissions

Granted on first use: Automation (controlling Spotify/Music), Calendars,
Notifications. Accessibility is required for Window Snap Zones (moving other
apps' windows) and Camera for the opt-in Mirror widget — both off until you
enable them. The app is ad-hoc signed; grants persist per build signature.

## Efficiency

Event-driven throughout — no polling while collapsed except a 0.5 s brightness
diff (HUD module only), a 6 s live-activity rotation tick and the Day Progress
60 s tick (both SwiftUI-coalesced, only while their view is on screen), and an
opt-in 60 s profile-switch timer that exists only when you configure schedule
rules. Measured: ~0.1% CPU (idle or playing — equalizer runs in the window
server via Core Animation), ~45 MB RSS.

## Requirements

macOS 14+. Best on Macs with a notch (MacBook Pro 2021+, MacBook Air M2+).
