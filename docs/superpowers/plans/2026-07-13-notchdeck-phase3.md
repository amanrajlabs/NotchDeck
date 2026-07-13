# NotchDeck Phase 3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Final MacNotch-parity modules — notifications strip, translation, Git PR views, Claude Code session monitor, screen-time donut — plus multi-display support.

**Architecture:** Same `NotchModule` pattern. Network modules (translation, Git) hold no timers; they fetch on demand/panel-appear. Screen time is event-driven (app-activation notifications, zero polling). Notifications read Apple's usernoted SQLite db (requires Full Disk Access, graceful CTA otherwise).

**Tech Stack:** SQLite3 C API + binary-plist parsing (notifications), URLSession (OpenAI/Ollama/GitHub/GitLab/Bitbucket REST), JSONL tail parsing (~/.claude/projects), NSWorkspace app-activation events.

## Global Constraints

Same as Phases 1–2. New: user-supplied API tokens live in UserDefaults via module settings panes (user enters them; nothing is fetched without a token).

## Tasks

### Task 1: Screen time → dashboard tile (ledger tested)
`Modules/Dashboard/ScreenTime.swift` — `UsageLedger` (pure, tested): `record(bundleID:from:to:)` accumulates per-app seconds per day, `today(top:)` returns top slices + other. `AppUsageTracker`: NSWorkspace.didActivateApplication events, persists JSON to App Support, feeds a donut `Canvas` tile added to the dashboard grid.

### Task 2: Notifications module (plist row parsing tested)
`Modules/Notifications/NotificationsDB.swift` — open `~/Library/Group Containers/group.com.apple.usernoted/db2/db` read-only via sqlite3; join `record`+`app`; `NotificationRowParser.parse(data:appID:date:)` (binary plist → title/subtitle/body, pure, tested). `NotificationsModule` — refresh on panel appear + 30 s while enabled; group by app; row click opens the app; no-FDA state shows a CTA button to the Full Disk Access pane.

### Task 3: Translation module
`Modules/Translation/TranslationModule.swift` — source text editor, target-language picker, engine picker (OpenAI `gpt-4o-mini` / Ollama local), translate button. Settings pane: OpenAI API key, Ollama URL+model. `TranslationResponseParser` (pure, tested) extracts text from both response shapes.

### Task 4: Git PRs module (payload parsing tested)
`Modules/Git/GitProviders.swift` — `PullRequest { title, repo, url, updated, provider }`; parsers for GitHub search API, GitLab MRs, Bitbucket PRs (pure, tested with fixtures). `GitModule` — fetch authored+review-requested on panel appear + manual refresh; settings pane per provider token (+ GitLab host, Bitbucket username); rows open in browser.

### Task 5: Claude Code monitor (tail parsing tested)
`Modules/Claude/ClaudeMonitor.swift` — scan `~/.claude/projects/*/*.jsonl` with mtime < 6 h; read last 64 KB; `ClaudeSessionParser.parse(tail:)` (pure, tested): last assistant `message.usage` tokens (input/output/cache-read), message count, model. Panel lists sessions: project name, active dot (mtime < 2 min), token usage; refresh on appear + 30 s while panel visible.

### Task 6: Multi-display
`SettingsStore.showOnAllDisplays` toggle. `NotchShellController` manages one panel+vm per target screen (notched screen always; others get simulated notch), rebuilt on screen-parameter changes. Modules/controllers stay shared singletons; each panel hosts its own `NotchRootView`.

### Task 7: Integration
ModuleSet + tab bar (shrink tabs to fit ~13 panels split across the notch), settings panes render via existing `settingsView()` hook. Checks for all pure parsers. Build, checks, bundle, relaunch, measure idle CPU.

## Self-Review
Spec Phase 3 coverage: notifications ✓(T2) translation ✓(T3) GitHub/GitLab/Bitbucket ✓(T4) Claude monitor ✓(T5) screen-time chart ✓(T1) multi-display ✓(T6). Claude terminal allow/deny prompts (MacNotch beta) intentionally out — needs deep terminal integration; noted in README.
