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

Planned: widget dashboard (weather, quick toggles, profiles), system monitor,
Pomodoro, Reminders tasks, notes (Phase 2); notifications strip, translation,
GitHub PRs, Claude Code monitor (Phase 3). See `docs/superpowers/specs/`.

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
Notifications. The app is ad-hoc signed; grants persist per build signature.

## Efficiency

Event-driven throughout — no polling while collapsed except a 0.5 s brightness
diff (HUD module only). Measured: ~0.1% CPU (idle or playing — equalizer runs in the window server via Core Animation), ~45 MB RSS.

## Requirements

macOS 14+. Best on Macs with a notch (MacBook Pro 2021+, MacBook Air M2+).
