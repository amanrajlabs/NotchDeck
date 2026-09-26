# NotchDeck

A native macOS notch productivity hub, inspired by [MacNotch](https://macnotch.io).
Swift 6 + SwiftUI, no third-party Swift dependencies, buildable with only Command
Line Tools (no Xcode required).

macOS 14+ · Apple Silicon & Intel · no account, no analytics, no telemetry.

**Network use:** the weather widget looks up your approximate location via
ipinfo.io and fetches forecasts from open-meteo.com (turn it off in
Settings → Dashboard widgets → Weather); album art is downloaded
from the player's artwork URL; Translation calls OpenAI (or your local Ollama)
and Pull Requests call GitHub/GitLab/Bitbucket — the last two only with keys
you enter. Nothing else leaves your Mac.

## Features

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

### More

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

## Install

Download the latest `NotchDeck-x.y.z.zip` from
[Releases](../../releases), unzip it, and drag **NotchDeck.app** to
`/Applications`.

### First launch: approving an unsigned app

NotchDeck is **ad-hoc signed but not notarized** — I'm not enrolled in the
$99/year Apple Developer Program. macOS therefore quarantines the download and
refuses the first launch with *"Apple could not verify NotchDeck is free of
malware."* This is Gatekeeper reporting the absence of a paid certificate, not
a detection of anything.

Approve it once, either way:

**System Settings** — try to open NotchDeck, then go to
Settings → Privacy & Security, scroll to *Security*, and click **Open Anyway**
next to the NotchDeck message. Confirm with Touch ID.

**Terminal** — strip the quarantine flag before the first launch:

```sh
xattr -dr com.apple.quarantine /Applications/NotchDeck.app
```

Prefer neither? [Build it from source](#build-from-source) — locally built
apps are never quarantined.

> **Updating:** because the app is ad-hoc signed, its code signature changes
> with every build. macOS may stop trusting earlier permission grants
> (Accessibility, Full Disk Access) after you replace the app. If a feature
> stops working after an update, remove NotchDeck from that list with **−**,
> then add it back with **+**. Tokens and API keys you enter are stored in
> your login keychain; after an update macOS may ask once whether NotchDeck
> can read them — choose **Always Allow**.

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

> **Private API notice:** system-wide now-playing info uses Apple's private
> MediaRemote framework. A future macOS update may break it; Spotify and Music
> keep working through their public scripting interfaces.

## Build from source

Command Line Tools are enough — no Xcode required:

```sh
./scripts/bundle.sh              # release build → dist/NotchDeck.app
./scripts/bundle.sh universal    # arm64+x86_64  → dist/NotchDeck.app
./scripts/release.sh             # universal zip → dist/NotchDeck-x.y.z.zip
swift run NotchDeckChecks        # run the checks (no XCTest under CLT)
```

## Credits

- [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) by
  Jonas van den Berg — vendored in `Vendor/mediaremote-adapter`, BSD 3-Clause.

## License

[MIT](LICENSE). Vendored code keeps its own license.
