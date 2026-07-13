# NotchDeck Phase 4 — Visual Parity Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the expanded UI to match MacNotch's observed design (studied from macnotch.io feature screenshots): in-panel headers, floating module dock, right rail, collapse button, adaptive panel heights, and per-module layouts. Reimplemented from observation — no third-party assets.

**Architecture:** Data layer (controllers/parsers) untouched. `NotchModule` gains presentation hooks (`preferredHeight`, `headerBadge()`, `headerActions()`). `ExpandedView` becomes generic chrome hosting module content.

## Chrome (all modules)

- Panel: 660pt wide, height per module (160–250pt), top flush with screen, bottom radius 18, vertical gradient `#1A1A1E → #060608`, 1px white@6% inner border, soft shadow.
- Header (~30pt) flows around the physical notch: left = bold title + optional badge; right = module actions + info button (opens Settings).
- Right rail: up to 5 tiny quick-switch icons of other modules, vertical, inside right edge.
- Collapse: small circled `arrow.down.right.and.arrow.up.left` bottom-right → collapses.
- Dock: floating row of 34pt circular buttons below the panel (8pt gap), one per enabled panel module, current highlighted; switches module.
- Window: 700×310 fixed while expanded; panel + dock top-anchored inside.

## Module layouts

1. **Media** — left: 84pt artwork, title 15/semibold, `artist · album` 11 gray; 2pt progress line + time captions; transport row (shuffle/back/play-circle 36pt/forward/repeat; shuffle+repeat only for scriptable players). Right: `NOW PLAYING` caption block w/ source app + dim animated bars. Header badge: source pill.
2. **Dashboard** — 2×4 widget grid: Events (next 2, blue time), Launcher (5 icons + "Set 1 of N" pager), Pomodoro mini (time + play/skip), Day Progress (NEW: workday bar 9:00–18:00, "Done ✓" after end); row 2: Quick toggles (circular icon buttons), Screen Time (donut + top-3 + switch count), Clock/Weather block (blue weekday, big day + clock, temp/condition, city, `Today · N events`), Actions (launchers 6–10). Header badge: profile pill.
3. **Calendar** — left: month grid (MON–SUN, dim adjacent months, today circled, event dots, ‹ › month nav + `Today` pill in header); right: agenda rows (blue time + end below, bold title, subtitle, trailing color dot).
4. **Todo List (tasks)** — left sidebar: All/Active/Done with counts; right: rows (time gray, bold title, due caption; hover: complete ○ and delete); header: `N active tasks` + `+` quick-add.
5. **Pomodoro** — columns: status (briefcase, `Work`, `Ready to focus`) + 76pt dial (time center, restart left, skip right, play under); presets list (Work/Short Break/Long Break/Quick Timer w/ minutes, tap to load); Focus Target list (today's events/reminders + `Select` pill; chosen target shown under status).
6. **Notes** — left: format toolbar grid (Bold/Italic/Strike/Code/List/Number/Heading → inserts markdown); right: editor. Header badge: note char count.
7. **Shelf (drop)** — dashed drop zone with staged file cards (icon + name); header: count badge; actions right: AirDrop, Zip, convert menu, folder (uses Copy⇄Move toggle pill), clear.
8. **PRs / MRs (git)** — left sidebar: `PRs / MRs` count + `Pipelines` placeholder; rows: initials avatar (provider color), bold title, `repo #n` + provider chip, ↗ open button. Empty state: key icon, `Connect providers`, explainer, Open Settings.
9. **AI Coding (claude)** — header `AI Coding (Beta)` + green `N active`; rows: cube tile, project bold, model line, mono preview of last assistant text, trailing age + `N msgs`.
10. **Notifications / Bluetooth / System** — keep content, adopt row-card styling + header counts.

## Engine additions

- `DayProgress` helper (pure, tested): fraction of configurable workday elapsed.
- ClaudeSessionParser: also extract last assistant text preview (tested).
- Settings keys: workday start/end hours.

## Verification

Checks extended (day-progress math, preview extraction). Build, bundle, launch, live-verify with user (hover states can't be automated).
