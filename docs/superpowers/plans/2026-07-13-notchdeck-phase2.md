# NotchDeck Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Five new modules — dashboard (weather/toggles/launchers/profiles), system monitor, Pomodoro, Reminders tasks, quick notes — matching MacNotch Phase 2 scope.

**Architecture:** Same `NotchModule` pattern as Phase 1. Samplers/timers run only while the owning panel is visible (system monitor) or a session is active (Pomodoro). Weather refreshes on activate + every 30 min.

**Tech Stack:** Open-Meteo + ipinfo.io (keyless HTTP), IOKit pmset assertions, private CoreBrightness via ObjC runtime (best effort), host_processor_info/host_statistics64, EventKit Reminders.

## Global Constraints

Same as Phase 1 (macOS 14+, no third-party deps, CLT-only build, checks in `NotchDeckChecks`, tested types public in NotchDeckKit).

## Tasks

### Task 1: Weather client (tested)
`Modules/Dashboard/Weather.swift` — `WeatherSnapshot { tempC, code, hiC, loC }`, `WeatherParser.parse(data:) -> WeatherSnapshot?` (Open-Meteo `current` + `daily` JSON, pure, tested), `symbol(for code:)` WMO→SF Symbol map (tested), `WeatherService` (@MainActor): ipinfo.io `loc` → lat/lon, fetch, 30-min refresh while active.

### Task 2: Quick toggles + launchers + profiles
`Modules/Dashboard/QuickToggles.swift` — `QuickToggleEngine`: darkMode (System Events AppleScript, state from effectiveAppearance + AppleInterfaceThemeChanged), keepAwake (IOPMAssertion), nightShift/trueTone (CoreBrightness classes via runtime; hidden when unavailable), hideDesktopIcons (Finder defaults + killall Finder).
`Modules/Dashboard/DashboardModule.swift` — grid: weather tile, toggle buttons, launcher row (user-picked apps, stored paths, NSOpenPanel add, context-menu remove), profile picker (Default/Work/Focus: each stores an enabled-module set; switching applies via ModuleRegistry).

### Task 3: System monitor (CPU math tested)
`Modules/SystemMonitor/SystemStats.swift` — `CPUSample` tick arrays, `cpuUsage(previous:current:) -> Double` (pure, tested); RAM via host_statistics64 (used = active+wired+compressed), storage via volumeAvailableCapacityForImportantUsage. `SystemMonitorModule` samples every 2 s **only while its panel is visible**.

### Task 4: Pomodoro (engine tested)
`Modules/Pomodoro/Pomodoro.swift` — `PomodoroEngine` (pure, injected clock): phases work/break, configurable minutes, `remaining(at:)`, `advanceIfElapsed(at:)` returns phase-completion events. Module: start/pause/reset UI, ring progress, live-activity countdown pill while running, UNUserNotification on phase end.

### Task 5: Tasks + Notes
`Modules/Tasks/TasksModule.swift` — EventKit Reminders (needs `NSRemindersFullAccessUsageDescription`): incomplete reminders in default list, complete-checkbox, quick-add field, denied-state CTA.
`Modules/Notes/NotesModule.swift` — TextEditor persisted to Application Support file, autosave debounce 1 s.

### Task 6: Integration
ModuleSet gains dashboard/system/pomodoro/tasks/notes (panel order: dashboard, media, calendar, tasks, notes, pomodoro, system, drop, bluetooth). ExpandedView splits tabs across both sides of the notch (left half + right half before gear). Info.plist adds Reminders usage string. Checks: weather parse, WMO symbols, CPU usage math, Pomodoro transitions. Build, `swift run NotchDeckChecks`, bundle, relaunch, measure idle.

## Self-Review
Spec Phase 2 list: dashboard ✓(T1-2) system monitor ✓(T3) Pomodoro ✓(T4) tasks ✓(T5) notes ✓(T5). Profiles ✓(T2). All tested pure parts named. Screen Time remains Phase 3 per spec.
