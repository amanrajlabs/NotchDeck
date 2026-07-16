# NotchDeck — AI Coding Module Design Spec

Approved 2026-07-16. Closes the one remaining MacNotch feature gap: a unified
"AI Coding" module tracking multiple CLI agents. NotchDeck currently ships a
Claude-only monitor ([ClaudeMonitor.swift](../../../Sources/NotchDeckKit/Modules/Claude/ClaudeMonitor.swift));
MacNotch's AI Coding (Beta) tracks multiple agents with a live "waiting for
approval" glance. This generalizes NotchDeck's module to **Claude Code + Codex**.

## Goals

- One module, one Settings toggle, one panel, covering multiple AI coding CLIs.
- Providers default-on: **Claude Code** and **Codex**, each independently toggleable.
- Surface a live **"waiting for approval"** glance in the collapsed strip and a
  notification when a session transitions into that state.
- Strictly **read + notify**. No keystroke injection, no writing to CLI state,
  no Cursor. (Interactivity decision, 2026-07-16: monitor-and-notify only.)
- Preserve the efficiency profile: event-driven (FSEvents), no polling, tail-only
  parsing.

## Non-goals (YAGNI)

- In-notch Allow/Deny buttons that inject keystrokes into the terminal.
- Cursor Agent support.
- Any mutation of CLI or terminal state.

## Architecture

### Provider abstraction

```
protocol AISessionProvider {
    var id: String { get }            // "claude-code" | "codex"
    var displayName: String { get }
    func watchRoots() -> [URL]        // dirs to FSEvent-watch
    func scan() -> [AISession]        // read-only, event-driven
}
```

- **ClaudeCodeProvider** — reuses the existing scan/tail logic over
  `~/.claude/projects/*/*.jsonl`. Refactored out of `ClaudeModule`.
- **CodexProvider** — new. Scans `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`.
  Parses line types: `session_meta` (cwd, model), `event_msg` /`response_item`
  (last agent message, function calls, token usage), `turn_context`.

### Unified model

```
struct AISession: Identifiable, Equatable, Sendable {
    var id: String                    // provider-prefixed session id
    var provider: String              // "claude-code" | "codex"
    var projectName: String
    var cwd: String?
    var model: String?
    var status: Status                // .running | .waitingApproval | .idle | .done
    var lastMessage: String?
    var tokens: Int
    var lastActivity: Date
}
```

### Waiting-for-approval detection (heuristic, per provider)

The JSONL logs do not record a discrete "waiting" flag, so status is inferred
from the tail:

- **Claude Code**: last event is an assistant `tool_use` with no following
  `user`/`tool_result` for that call, and `lastActivity` older than
  `approvalThreshold` (~4 s) → `.waitingApproval`. Younger → `.running`.
- **Codex**: last `response_item` is a `function_call` (e.g. exec / apply_patch)
  with no matching `function_call_output`, same threshold logic.

The threshold avoids flagging a tool that is merely still executing. This is a
best-effort glance signal only; it never drives an action.

### Surfacing (reuse existing infra)

- **Collapsed strip**: `.waitingApproval` sessions feed the live-rotation
  ([LiveRotation.swift](../../../Sources/NotchDeckKit/Shell/LiveRotation.swift))
  as a "⏳ waiting" glance with a provider-colored dot.
- **Notification**: fire on transition *into* `.waitingApproval`, deduped per
  session id. Body = `projectName · tool`. Requires the app's existing
  `UNUserNotificationCenter` authorization; degrades silently without it.
- **Click action (best-effort focus)**: clicking a waiting session tries to
  raise its terminal — match `cwd` to a running `claude`/`codex` process, then
  activate that process's terminal app via `NSRunningApplication`. If it cannot
  be resolved, the click expands the session's detail row instead. No keystrokes
  are sent.
- **Panel**: sections grouped by provider; each row shows dot, model, project,
  status, last message, token count. Session list is expandable in height (matches
  MacNotch's expandable list).

### Settings

Under a renamed **AI Coding** pane: master module toggle + per-provider toggles
(Claude Code / Codex), both default-on. A disabled provider registers no FSEvents
watch and contributes no sessions.

### Efficiency

- FSEvents watch on each enabled provider's `watchRoots()`; no timers while idle.
- Parse only the tail of changed files (extend the existing `tailString` byte-tail
  read to Codex rollout files).
- Live-rotation tick and any transient UI timers exist only while their view is on
  screen, per the app's existing rules. Target unchanged: ~0.1% idle CPU.

## Migration / compatibility

- `ClaudeModule` is generalized to `AICodingModule`; module id changes from
  `claude` to `ai-coding`. Migrate the persisted module-order / default-module
  entries so existing users don't lose their layout (map old `claude` id →
  `ai-coding`).
- The Claude-specific token badge/header logic is preserved as the Claude
  provider's contribution to the unified row.

## Testing

Pure, table-tested parsers (no XCTest under CLT — added to `NotchDeckChecks`):

- **CodexRolloutParser**: fixture rollout lines → `AISession` (model, cwd,
  project, tokens, last message).
- **Waiting detection**: fixtures for each provider covering
  running / waiting / idle / done, including the threshold boundary.
- **Settings migration**: old `claude` module id maps to `ai-coding` in
  persisted order/default.

## File plan

- `Modules/AICoding/AISession.swift` — model + `AISessionProvider` protocol.
- `Modules/AICoding/ClaudeCodeProvider.swift` — moved from `ClaudeMonitor.swift`.
- `Modules/AICoding/CodexProvider.swift` — new parser + scanner.
- `Modules/AICoding/AICodingModule.swift` — module, panel, live activity, notify.
- `Modules/AICoding/AICodingViews.swift` — panel + row views.
- Settings pane update; module registry + persistence migration.
- `NotchDeckChecks/main.swift` — parser and migration checks.
