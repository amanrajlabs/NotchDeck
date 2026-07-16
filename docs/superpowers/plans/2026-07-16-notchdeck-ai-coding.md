# AI Coding Module Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generalize NotchDeck's Claude-only monitor into a unified "AI Coding" module that tracks Claude Code **and** Codex sessions, surfacing a live "waiting for approval" glance and notification — read-only, no keystroke injection.

**Architecture:** A provider abstraction (`AISessionProvider`) yields a common `AISession` model from each CLI's on-disk JSONL logs. Pure parsers (`ClaudeSessionParser`, `CodexRolloutParser`) plus a shared status rule (`AIStatusRule`) are unit-tested in `NotchDeckChecks`. `AICodingModule` aggregates providers, renders the panel/live-activity, watches the log roots via FSEvents, and notifies on transition into `.waitingApproval`. Replaces `ClaudeModule` (id `claude` → `ai-coding`) with persisted-order migration.

**Tech Stack:** Swift 6, SwiftUI, Foundation (`JSONSerialization`, `FileHandle`, `FSEventStream`), no third-party dependencies. Tests run via `swift run NotchDeckChecks`.

## Global Constraints

- Swift 6, SwiftUI, no external dependencies (matches repo).
- Build with Command Line Tools only — no XCTest; tests are `expect(...)` assertions in `Sources/NotchDeckChecks/main.swift`.
- Event-driven only: no polling loops. FSEvents watch active only while the module is enabled. Preserve ~0.1% idle CPU.
- Read-only: never write to CLI state, never inject keystrokes.
- Providers default-on: `claude-code`, `codex`.
- Session id format: `"<provider-id>:<file-path>"`.
- Waiting-approval threshold: `4` seconds. "Active/running" recency window: `120` seconds (matches existing `ClaudeSession.isActive`).
- After any source change, verify with `swift run NotchDeckChecks`; for on-device checks, `bash scripts/bundle.sh` then relaunch.
- Commits are LOCAL only (repo has no remote). Never push.

---

### Task 1: AISession model, provider protocol, and status rule

**Files:**
- Create: `Sources/NotchDeckKit/Modules/AICoding/AISession.swift`
- Test: `Sources/NotchDeckChecks/main.swift` (append)

**Interfaces:**
- Produces: `AISession` struct; `AISession.Status` enum; `AISessionProvider` protocol; `AIStatusRule.status(hasPendingCall:finished:lastActivity:now:)`.

- [ ] **Step 1: Write the model, protocol, and rule**

```swift
// Sources/NotchDeckKit/Modules/AICoding/AISession.swift
import Foundation

public struct AISession: Identifiable, Equatable, Sendable {
    public enum Status: String, Sendable {
        case running, waitingApproval, idle, done
    }

    public var id: String            // "<provider>:<file-path>"
    public var provider: String      // "claude-code" | "codex"
    public var projectName: String
    public var cwd: String?
    public var model: String?
    public var status: Status
    public var lastMessage: String?
    public var tokens: Int
    public var lastActivity: Date

    public init(id: String, provider: String, projectName: String, cwd: String?,
                model: String?, status: Status, lastMessage: String?,
                tokens: Int, lastActivity: Date) {
        self.id = id
        self.provider = provider
        self.projectName = projectName
        self.cwd = cwd
        self.model = model
        self.status = status
        self.lastMessage = lastMessage
        self.tokens = tokens
        self.lastActivity = lastActivity
    }
}

/// A source of AI coding sessions read from on-disk logs. Stateless; scan() is
/// safe to call off the main thread.
public protocol AISessionProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    /// Directories to FSEvent-watch for changes.
    func watchRoots() -> [URL]
    /// Read-only scan of the provider's logs into unified sessions.
    func scan() -> [AISession]
}

/// Pure status decision shared by all providers.
public enum AIStatusRule {
    public static let approvalThreshold: TimeInterval = 4
    public static let activeWindow: TimeInterval = 120

    /// - hasPendingCall: an unmatched tool_use / function_call sits at the tail.
    /// - finished: the session logged a completion after its last tool activity.
    public static func status(hasPendingCall: Bool, finished: Bool,
                              lastActivity: Date, now: Date = Date()) -> AISession.Status {
        if hasPendingCall {
            return now.timeIntervalSince(lastActivity) >= approvalThreshold
                ? .waitingApproval : .running
        }
        if finished { return now.timeIntervalSince(lastActivity) < activeWindow ? .done : .idle }
        return now.timeIntervalSince(lastActivity) < activeWindow ? .running : .idle
    }
}
```

- [ ] **Step 2: Write the failing test** (append to `main.swift`, before `// MARK: - MeetingDetector`)

```swift
// MARK: - AIStatusRule
let ref = Date(timeIntervalSince1970: 1_000_000)
expect(AIStatusRule.status(hasPendingCall: true, finished: false,
    lastActivity: ref.addingTimeInterval(-10), now: ref) == .waitingApproval,
    "pending call past threshold → waitingApproval")
expect(AIStatusRule.status(hasPendingCall: true, finished: false,
    lastActivity: ref.addingTimeInterval(-1), now: ref) == .running,
    "pending call within threshold → running")
expect(AIStatusRule.status(hasPendingCall: false, finished: true,
    lastActivity: ref.addingTimeInterval(-5), now: ref) == .done,
    "finished + recent → done")
expect(AIStatusRule.status(hasPendingCall: false, finished: false,
    lastActivity: ref.addingTimeInterval(-500), now: ref) == .idle,
    "no activity, stale → idle")
```

- [ ] **Step 3: Run and verify pass**

Run: `swift run NotchDeckChecks 2>&1 | tail -3`
Expected: `OK — N checks passed` (N increased by 4).

- [ ] **Step 4: Commit**

```bash
git add Sources/NotchDeckKit/Modules/AICoding/AISession.swift Sources/NotchDeckChecks/main.swift
git commit -m "feat: AISession model, provider protocol, status rule"
```

---

### Task 2: Codex rollout parser

**Files:**
- Create: `Sources/NotchDeckKit/Modules/AICoding/CodexRolloutParser.swift`
- Test: `Sources/NotchDeckChecks/main.swift` (append)

**Interfaces:**
- Consumes: nothing from other tasks (pure).
- Produces: `CodexRolloutParser.Parsed` struct (`model`, `cwd`, `tokens`, `lastMessage`, `hasPendingCall`, `finished`); `CodexRolloutParser.parse(lines:) -> Parsed`; `CodexRolloutParser.projectName(fromCwd:) -> String`.

Codex rollout files are `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`. Each line is `{"type", "timestamp", "payload"}`. Relevant payloads:
- `session_meta` → `cwd`.
- `turn_context` → `model` (e.g. `"gpt-5.5"`), `cwd`.
- `response_item` with `payload.type == "function_call"` → `call_id`, `name`, `arguments`.
- `response_item` with `payload.type == "function_call_output"` → `call_id`.
- `response_item` with `payload.type == "message"`, `role == "assistant"` → `content: [{type:"output_text", text}]`.
- `event_msg` with `payload.type == "agent_message"` → `message`.
- `event_msg` with `payload.type == "token_count"` → `info.total_token_usage.total_tokens`.
- `event_msg` with `payload.type == "task_complete"` → completion marker.

- [ ] **Step 1: Write the failing test** (append)

```swift
// MARK: - CodexRolloutParser
let codexWaiting = """
{"type":"session_meta","payload":{"cwd":"/Users/aman/Desktop/Proj"}}
{"type":"turn_context","payload":{"model":"gpt-5.5","cwd":"/Users/aman/Desktop/Proj"}}
{"type":"event_msg","payload":{"type":"agent_message","message":"Running the build now."}}
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":24030}}}}
{"type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call_A","arguments":"{}"}}
"""
let cw = CodexRolloutParser.parse(lines: codexWaiting)
expect(cw.model == "gpt-5.5", "codex model from turn_context")
expect(cw.cwd == "/Users/aman/Desktop/Proj", "codex cwd")
expect(cw.tokens == 24030, "codex total tokens")
expect(cw.lastMessage == "Running the build now.", "codex last agent message")
expect(cw.hasPendingCall == true, "codex unmatched function_call → pending")
expect(cw.finished == false, "codex not finished")
expect(CodexRolloutParser.projectName(fromCwd: "/Users/aman/Desktop/Proj") == "Proj", "codex project name")

let codexDone = codexWaiting + """

{"type":"response_item","payload":{"type":"function_call_output","call_id":"call_A","output":"ok"}}
{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"Done."}}
"""
let cd = CodexRolloutParser.parse(lines: codexDone)
expect(cd.hasPendingCall == false, "codex matched call → not pending")
expect(cd.finished == true, "codex task_complete → finished")
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift run NotchDeckChecks 2>&1 | tail -5`
Expected: compile error `cannot find 'CodexRolloutParser'`.

- [ ] **Step 3: Write the parser**

```swift
// Sources/NotchDeckKit/Modules/AICoding/CodexRolloutParser.swift
import Foundation

/// Parses the tail of a Codex rollout JSONL. Pure and tested.
public enum CodexRolloutParser {
    public struct Parsed: Equatable, Sendable {
        public var model: String?
        public var cwd: String?
        public var tokens: Int
        public var lastMessage: String?
        public var hasPendingCall: Bool
        public var finished: Bool
        public init(model: String? = nil, cwd: String? = nil, tokens: Int = 0,
                    lastMessage: String? = nil, hasPendingCall: Bool = false,
                    finished: Bool = false) {
            self.model = model; self.cwd = cwd; self.tokens = tokens
            self.lastMessage = lastMessage; self.hasPendingCall = hasPendingCall
            self.finished = finished
        }
    }

    public static func parse(lines: String) -> Parsed {
        var result = Parsed()
        var openCalls = Set<String>()      // function_call call_ids awaiting output
        var lastEventWasCompletion = false
        for line in lines.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = root["payload"] as? [String: Any] else { continue }
            let type = root["type"] as? String
            let ptype = payload["type"] as? String
            switch (type, ptype) {
            case ("session_meta", _):
                if let cwd = payload["cwd"] as? String { result.cwd = cwd }
            case ("turn_context", _):
                if let model = payload["model"] as? String { result.model = model }
                if let cwd = payload["cwd"] as? String { result.cwd = cwd }
            case ("event_msg", "agent_message"):
                if let msg = (payload["message"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !msg.isEmpty {
                    result.lastMessage = String(msg.prefix(140))
                }
                lastEventWasCompletion = false
            case ("event_msg", "token_count"):
                if let info = payload["info"] as? [String: Any],
                   let usage = info["total_token_usage"] as? [String: Any],
                   let total = (usage["total_tokens"] as? NSNumber)?.intValue {
                    result.tokens = total
                }
            case ("event_msg", "task_complete"):
                lastEventWasCompletion = true
            case ("response_item", "function_call"):
                if let callID = payload["call_id"] as? String { openCalls.insert(callID) }
                lastEventWasCompletion = false
            case ("response_item", "function_call_output"):
                if let callID = payload["call_id"] as? String { openCalls.remove(callID) }
            case ("response_item", "message"):
                lastEventWasCompletion = false
            default:
                break
            }
        }
        result.hasPendingCall = !openCalls.isEmpty
        result.finished = lastEventWasCompletion && openCalls.isEmpty
        return result
    }

    /// "/Users/aman/Desktop/Proj" → "Proj"
    public static func projectName(fromCwd cwd: String) -> String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift run NotchDeckChecks 2>&1 | tail -3`
Expected: `OK — N checks passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/NotchDeckKit/Modules/AICoding/CodexRolloutParser.swift Sources/NotchDeckChecks/main.swift
git commit -m "feat: Codex rollout parser with pending-call detection"
```

---

### Task 3: Claude pending-tool-use detection

**Files:**
- Modify: `Sources/NotchDeckKit/Modules/Claude/ClaudeMonitor.swift:34-81` (extend `TailStats` + `parse`)
- Test: `Sources/NotchDeckChecks/main.swift` (append)

**Interfaces:**
- Consumes: existing `ClaudeSessionParser.TailStats`.
- Produces: `TailStats.hasPendingToolUse: Bool` field.

Claude JSONL: assistant tool calls are `type:"assistant"`, `message.content: [{type:"tool_use", id}]`; results are `type:"user"`, `message.content: [{type:"tool_result", tool_use_id}]`. A pending tool use is a `tool_use` id with no later matching `tool_result`.

- [ ] **Step 1: Add the field to `TailStats`** (in `ClaudeMonitor.swift`, inside the struct after `preview`)

```swift
        /// True when a tool_use in the tail has no following tool_result.
        public var hasPendingToolUse: Bool
```

Update the initializer signature and body to include it (default `false`):

```swift
        public init(model: String? = nil, inputTokens: Int = 0, outputTokens: Int = 0,
                    cacheReadTokens: Int = 0, assistantMessages: Int = 0, preview: String? = nil,
                    hasPendingToolUse: Bool = false) {
            self.model = model
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheReadTokens = cacheReadTokens
            self.assistantMessages = assistantMessages
            self.preview = preview
            self.hasPendingToolUse = hasPendingToolUse
        }
```

- [ ] **Step 2: Track tool_use / tool_result in `parse`**

Replace the body of `parse(tail:)` so it also walks `user` rows. Add a `Set<String> openToolUses` and process both types:

```swift
    public static func parse(tail: String) -> TailStats {
        var stats = TailStats()
        var openToolUses = Set<String>()
        for line in tail.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = root["message"] as? [String: Any] else { continue }
            let rowType = root["type"] as? String
            if rowType == "assistant" {
                stats.assistantMessages += 1
                if let model = message["model"] as? String { stats.model = model }
                if let usage = message["usage"] as? [String: Any] {
                    stats.inputTokens = (usage["input_tokens"] as? NSNumber)?.intValue ?? stats.inputTokens
                    stats.outputTokens = (usage["output_tokens"] as? NSNumber)?.intValue ?? stats.outputTokens
                    stats.cacheReadTokens = (usage["cache_read_input_tokens"] as? NSNumber)?.intValue ?? stats.cacheReadTokens
                }
                if let blocks = message["content"] as? [[String: Any]] {
                    for block in blocks {
                        switch block["type"] as? String {
                        case "text":
                            if let text = (block["text"] as? String)?
                                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                                stats.preview = String(text.prefix(140))
                            }
                        case "tool_use":
                            if let id = block["id"] as? String { openToolUses.insert(id) }
                        default:
                            break
                        }
                    }
                }
            } else if rowType == "user", let blocks = message["content"] as? [[String: Any]] {
                for block in blocks where block["type"] as? String == "tool_result" {
                    if let id = block["tool_use_id"] as? String { openToolUses.remove(id) }
                }
            }
        }
        stats.hasPendingToolUse = !openToolUses.isEmpty
        return stats
    }
```

- [ ] **Step 3: Write the test** (append)

```swift
// MARK: - Claude pending tool_use
let claudePending = """
{"type":"assistant","message":{"model":"claude-opus-4-8","content":[{"type":"tool_use","id":"tu_1","name":"Bash"}]}}
"""
expect(ClaudeSessionParser.parse(tail: claudePending).hasPendingToolUse == true,
    "unmatched tool_use → pending")
let claudeResolved = claudePending + """

{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu_1"}]}}
"""
expect(ClaudeSessionParser.parse(tail: claudeResolved).hasPendingToolUse == false,
    "matched tool_result → not pending")
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift run NotchDeckChecks 2>&1 | tail -3`
Expected: `OK — N checks passed`. (Existing Claude parser tests still pass — behavior unchanged for the fields they check.)

- [ ] **Step 5: Commit**

```bash
git add Sources/NotchDeckKit/Modules/Claude/ClaudeMonitor.swift Sources/NotchDeckChecks/main.swift
git commit -m "feat: detect pending tool_use in Claude session tail"
```

---

### Task 4: ClaudeCodeProvider

**Files:**
- Create: `Sources/NotchDeckKit/Modules/AICoding/ClaudeCodeProvider.swift`
- Test: `Sources/NotchDeckChecks/main.swift` (append)

**Interfaces:**
- Consumes: `AISession`, `AISessionProvider`, `AIStatusRule` (Task 1); `ClaudeSessionParser` (Task 3).
- Produces: `struct ClaudeCodeProvider: AISessionProvider`. Reuses the scan/tail logic currently in `ClaudeModule.scan` / `tailString`.

- [ ] **Step 1: Write the provider**

```swift
// Sources/NotchDeckKit/Modules/AICoding/ClaudeCodeProvider.swift
import Foundation

public struct ClaudeCodeProvider: AISessionProvider {
    public let id = "claude-code"
    public let displayName = "Claude Code"
    public init() {}

    private var projectsDir: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects")
    }

    public func watchRoots() -> [URL] { [projectsDir] }

    public func scan() -> [AISession] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: nil) else { return [] }
        var sessions: [AISession] = []
        let cutoff = Date().addingTimeInterval(-6 * 3600)
        for dir in projectDirs {
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            let recent = files
                .filter { $0.pathExtension == "jsonl" }
                .compactMap { url -> (URL, Date)? in
                    guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate, modified > cutoff else { return nil }
                    return (url, modified)
                }
                .max { $0.1 < $1.1 }
            guard let (file, modified) = recent,
                  let tail = AILogTail.tailString(of: file, bytes: 64 * 1024) else { continue }
            let stats = ClaudeSessionParser.parse(tail: tail)
            let status = AIStatusRule.status(
                hasPendingCall: stats.hasPendingToolUse, finished: false, lastActivity: modified)
            sessions.append(AISession(
                id: "\(id):\(file.path)",
                provider: id,
                projectName: ClaudeSessionParser.projectName(fromDirName: dir.lastPathComponent),
                cwd: nil,
                model: stats.model,
                status: status,
                lastMessage: stats.preview,
                tokens: stats.inputTokens + stats.cacheReadTokens + stats.outputTokens,
                lastActivity: modified))
        }
        return sessions
    }
}

/// Shared byte-tail reader for provider log files.
public enum AILogTail {
    public static func tailString(of url: URL, bytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}
```

- [ ] **Step 2: Write a smoke test** (append — verifies protocol conformance + id/root shape without depending on live files)

```swift
// MARK: - ClaudeCodeProvider
let ccp = ClaudeCodeProvider()
expect(ccp.id == "claude-code", "claude provider id")
expect(ccp.watchRoots().first?.lastPathComponent == "projects", "claude watch root is ~/.claude/projects")
_ = ccp.scan()   // must not crash on the live filesystem
```

- [ ] **Step 3: Run to verify it passes**

Run: `swift run NotchDeckChecks 2>&1 | tail -3`
Expected: `OK — N checks passed`.

- [ ] **Step 4: Commit**

```bash
git add Sources/NotchDeckKit/Modules/AICoding/ClaudeCodeProvider.swift Sources/NotchDeckChecks/main.swift
git commit -m "feat: ClaudeCodeProvider yielding unified AISession"
```

---

### Task 5: CodexProvider

**Files:**
- Create: `Sources/NotchDeckKit/Modules/AICoding/CodexProvider.swift`
- Test: `Sources/NotchDeckChecks/main.swift` (append)

**Interfaces:**
- Consumes: `AISession`, `AISessionProvider`, `AIStatusRule` (Task 1); `CodexRolloutParser` (Task 2); `AILogTail` (Task 4).
- Produces: `struct CodexProvider: AISessionProvider`.

Codex sessions live under `~/.codex/sessions/<year>/<month>/<day>/rollout-*.jsonl`. Scan recent files by modification date (a shallow recursive walk of the sessions dir, filtered to `rollout-*.jsonl` newer than 6h).

- [ ] **Step 1: Write the provider**

```swift
// Sources/NotchDeckKit/Modules/AICoding/CodexProvider.swift
import Foundation

public struct CodexProvider: AISessionProvider {
    public let id = "codex"
    public let displayName = "Codex"
    public init() {}

    private var sessionsDir: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/.codex/sessions")
    }

    public func watchRoots() -> [URL] { [sessionsDir] }

    public func scan() -> [AISession] {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-6 * 3600)
        guard let walker = fm.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return [] }
        var sessions: [AISession] = []
        for case let url as URL in walker {
            guard url.pathExtension == "jsonl",
                  url.lastPathComponent.hasPrefix("rollout-"),
                  let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate, modified > cutoff,
                  let tail = AILogTail.tailString(of: url, bytes: 64 * 1024) else { continue }
            let parsed = CodexRolloutParser.parse(lines: tail)
            let status = AIStatusRule.status(
                hasPendingCall: parsed.hasPendingCall, finished: parsed.finished, lastActivity: modified)
            let project = parsed.cwd.map(CodexRolloutParser.projectName(fromCwd:))
                ?? url.deletingPathExtension().lastPathComponent
            sessions.append(AISession(
                id: "\(id):\(url.path)",
                provider: id,
                projectName: project,
                cwd: parsed.cwd,
                model: parsed.model,
                status: status,
                lastMessage: parsed.lastMessage,
                tokens: parsed.tokens,
                lastActivity: modified))
        }
        return sessions
    }
}
```

- [ ] **Step 2: Write a smoke test** (append)

```swift
// MARK: - CodexProvider
let cxp = CodexProvider()
expect(cxp.id == "codex", "codex provider id")
expect(cxp.watchRoots().first?.lastPathComponent == "sessions", "codex watch root is ~/.codex/sessions")
_ = cxp.scan()   // must not crash on the live filesystem
```

- [ ] **Step 3: Run to verify it passes**

Run: `swift run NotchDeckChecks 2>&1 | tail -3`
Expected: `OK — N checks passed`.

- [ ] **Step 4: Commit**

```bash
git add Sources/NotchDeckKit/Modules/AICoding/CodexProvider.swift Sources/NotchDeckChecks/main.swift
git commit -m "feat: CodexProvider scanning rollout logs"
```

---

### Task 6: FSEvents directory watcher

**Files:**
- Create: `Sources/NotchDeckKit/Modules/AICoding/DirectoryWatcher.swift`
- Test: manual (FSEvents needs a runloop; covered by Task 11 end-to-end verify).

**Interfaces:**
- Produces: `final class DirectoryWatcher` with `init(paths:[String], onChange:@escaping @Sendable () -> Void)`, `start()`, `stop()`. Coalesces bursts with a 0.4s latency.

- [ ] **Step 1: Write the watcher**

```swift
// Sources/NotchDeckKit/Modules/AICoding/DirectoryWatcher.swift
import CoreServices
import Foundation

/// Watches directory trees via FSEvents and fires onChange (coalesced) on the
/// main queue. No polling.
public final class DirectoryWatcher {
    private let paths: [String]
    private let onChange: @Sendable () -> Void
    private var stream: FSEventStreamRef?

    public init(paths: [String], onChange: @escaping @Sendable () -> Void) {
        self.paths = paths
        self.onChange = onChange
    }

    public func start() {
        guard stream == nil, !paths.isEmpty else { return }
        let info = Unmanaged.passRetained(Box(onChange)).toOpaque()
        var context = FSEventStreamContext(
            version: 0, info: info, retain: nil,
            release: { ptr in ptr.map { Unmanaged<Box>.fromOpaque($0).release() } },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            box.fire()
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.4,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)) else {
            Unmanaged<Box>.fromOpaque(info).release()
            return
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private final class Box {
        let onChange: @Sendable () -> Void
        init(_ onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
        func fire() { onChange() }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/NotchDeckKit/Modules/AICoding/DirectoryWatcher.swift
git commit -m "feat: FSEvents directory watcher for AI coding logs"
```

---

### Task 7: AICodingModule + panel/live views

**Files:**
- Create: `Sources/NotchDeckKit/Modules/AICoding/AICodingModule.swift`
- Create: `Sources/NotchDeckKit/Modules/AICoding/AICodingViews.swift`
- Delete: `Sources/NotchDeckKit/Modules/Claude/ClaudeMonitor.swift` **only the module/view parts** — keep `ClaudeSession`? No: `ClaudeSession`/`ClaudeModule`/`ClaudePanelView`/`SessionRow`/`ClaudeModuleShared` are replaced. Keep `ClaudeSessionParser` — MOVE it into `ClaudeCodeProvider.swift` or leave the file with only the parser. Simplest: strip `ClaudeMonitor.swift` down to just `ClaudeSessionParser`.
- Modify: wherever `ClaudeModule()` is registered (find with grep in Step 1).

**Interfaces:**
- Consumes: all providers (Tasks 4–5), `DirectoryWatcher` (Task 6), `NotchModule` protocol, `Theme`, `SettingsStore`.
- Produces: `final class AICodingModule: NotchModule, ObservableObject` with `static let moduleID = "ai-coding"` and `@Published var sessions: [AISession]`.

- [ ] **Step 1: Find registration + strip old module**

Run: `grep -rn "ClaudeModule\|ClaudeModuleShared\|ClaudePanelView\|struct SessionRow\|ClaudeSession(" Sources/`
Note every hit. In `ClaudeMonitor.swift`, delete everything from `// MARK: - Module` (line ~89) to end of file, leaving only `ClaudeSession`? — `ClaudeSession` is now unused; delete it too. Keep only `ClaudeSessionParser`. Rename the file's remaining content is fine in place.

- [ ] **Step 2: Write the module**

```swift
// Sources/NotchDeckKit/Modules/AICoding/AICodingModule.swift
import SwiftUI

@MainActor
final class AICodingModule: NotchModule, ObservableObject {
    static let moduleID = "ai-coding"
    let id = AICodingModule.moduleID
    let name = "AI Coding"
    let icon = "sparkles"
    let hasPanel = true
    var preferredHeight: CGFloat { 200 }

    @Published private(set) var sessions: [AISession] = []

    private let settings: SettingsStore
    private var watcher: DirectoryWatcher?
    private var notifiedWaiting = Set<String>()

    init(settings: SettingsStore) { self.settings = settings }

    private var activeProviders: [AISessionProvider] {
        var providers: [AISessionProvider] = []
        if settings.isAIProviderEnabled("claude-code") { providers.append(ClaudeCodeProvider()) }
        if settings.isAIProviderEnabled("codex") { providers.append(CodexProvider()) }
        return providers
    }

    func activate() {
        let roots = activeProviders.flatMap { $0.watchRoots() }
            .map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
        let watcher = DirectoryWatcher(paths: roots) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        watcher.start()
        self.watcher = watcher
        AICodingShared.instance = self
        refresh()
    }

    func deactivate() {
        watcher?.stop()
        watcher = nil
        sessions = []
        notifiedWaiting.removeAll()
    }

    /// Re-scan providers off the main thread, publish sorted results on main.
    func refresh() {
        let providers = activeProviders
        Task.detached(priority: .utility) {
            let found = providers.flatMap { $0.scan() }
                .sorted { $0.lastActivity > $1.lastActivity }
            await MainActor.run { AICodingShared.instance?.apply(found) }
        }
    }

    private func apply(_ found: [AISession]) {
        if sessions != found { sessions = found }
        notifyWaiting(found)   // implemented in Task 9
    }

    func panelView() -> AnyView { AnyView(AICodingPanelView(module: self)) }

    func liveActivityView() -> AnyView? {
        guard let waiting = sessions.first(where: { $0.status == .waitingApproval }) else { return nil }
        return AnyView(AIWaitingPill(session: waiting))
    }

    func headerBadge() -> AnyView? {
        let running = sessions.filter { $0.status == .running || $0.status == .waitingApproval }.count
        return AnyView(
            HStack(spacing: 5) {
                Text("(Beta)").font(.system(size: 9)).foregroundStyle(.tertiary)
                if running > 0 {
                    Circle().fill(Color.green).frame(width: 5, height: 5)
                    Text("\(running) active").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.green)
                }
            })
    }
}

@MainActor
enum AICodingShared { weak static var instance: AICodingModule? }
```

- [ ] **Step 3: Write the views**

```swift
// Sources/NotchDeckKit/Modules/AICoding/AICodingViews.swift
import SwiftUI

private func providerColor(_ provider: String) -> Color {
    provider == "codex" ? .cyan : .orange
}

struct AIWaitingPill: View {
    let session: AISession
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "hourglass").font(.system(size: 10))
            Text(session.projectName).font(.system(size: 10, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(.yellow)
    }
}

struct AICodingPanelView: View {
    @ObservedObject var module: AICodingModule
    var body: some View {
        Group {
            if module.sessions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("No recent AI coding sessions").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(module.sessions) { session in
                            AISessionRow(session: session) { module.focus(session) }  // focus: Task 10
                        }
                    }
                }
            }
        }
        .onAppear { module.refresh() }
    }
}

struct AISessionRow: View {
    let session: AISession
    let onTap: () -> Void
    @State private var hovering = false

    private var statusText: String {
        switch session.status {
        case .waitingApproval: "waiting for approval"
        case .running: "running"
        case .done: "done"
        case .idle: "idle"
        }
    }
    private var statusColor: Color {
        switch session.status {
        case .waitingApproval: .yellow
        case .running: .green
        default: .secondary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            RoundedRectangle(cornerRadius: 6)
                .fill(providerColor(session.provider).opacity(0.18))
                .overlay(Circle().fill(statusColor).frame(width: 6, height: 6))
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(session.projectName).font(.system(size: 11, weight: .bold)).lineLimit(1)
                    if let model = session.model {
                        Text(model.replacingOccurrences(of: "claude-", with: ""))
                            .font(.system(size: 8)).foregroundStyle(.tertiary)
                    }
                }
                Text(statusText).font(.system(size: 8)).foregroundStyle(statusColor)
                if let msg = session.lastMessage {
                    Text(msg).font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 1) {
                Text(session.lastActivity, style: .relative)
                    .font(.system(size: 8)).foregroundStyle(.tertiary)
                Text("\(AISessionRow.compact(session.tokens)) tok")
                    .font(.system(size: 8).monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Theme.cardHover : Theme.card))
        .onHover { hovering = $0 }
        .onTapGesture { onTap() }
    }

    static func compact(_ n: Int) -> String {
        switch n {
        case 1_000_000...: String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: String(format: "%.1fk", Double(n) / 1_000)
        default: "\(n)"
        }
    }
}
```

Note: `module.focus(session)` and `settings.isAIProviderEnabled` / `notifyWaiting` are added in Tasks 9–10. To compile this task standalone, add temporary stubs: in `AICodingModule` add `func focus(_ session: AISession) {}` and `private func notifyWaiting(_ s: [AISession]) {}`, and in `SettingsStore` add `func isAIProviderEnabled(_ id: String) -> Bool { true }`. Tasks 9–10 replace the stubs.

- [ ] **Step 4: Register the module** — in `Sources/NotchDeckKit/Shell/NotchRootView.swift` (`ModuleSet`), make three edits:
  1. Line 22: `let claude: ClaudeModule` → `let aiCoding: AICodingModule`.
  2. Line 40 (inside `init(settings:)`, where `settings` is already in scope — same pattern as `hud = HUDModule(settings: settings)`): `claude = ClaudeModule()` → `aiCoding = AICodingModule(settings: settings)`.
  3. Line 44 (`var all`): replace `claude` with `aiCoding` in the array.

- [ ] **Step 5: Build + checks**

Run: `swift build 2>&1 | tail -3 && swift run NotchDeckChecks 2>&1 | tail -3`
Expected: `Build complete!` and `OK — N checks passed`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: AICodingModule aggregating Claude Code + Codex providers"
```

---

### Task 8: Settings module-id migration

**Files:**
- Modify: `Sources/NotchDeckKit/Settings/SettingsStore.swift`
- Create helper: `Sources/NotchDeckKit/Modules/AICoding/AICodingMigration.swift`
- Test: `Sources/NotchDeckChecks/main.swift` (append)

**Interfaces:**
- Produces: `AICodingMigration.migrate(order:enabledKey:defaultModule:) -> (order:[String], defaultModule:String?)` pure function mapping `"claude"` → `"ai-coding"`.

- [ ] **Step 1: Write the pure migration**

```swift
// Sources/NotchDeckKit/Modules/AICoding/AICodingMigration.swift
import Foundation

/// Maps the legacy "claude" module id to "ai-coding" wherever it was persisted.
public enum AICodingMigration {
    public static let oldID = "claude"
    public static let newID = "ai-coding"

    public static func migrate(order: [String], defaultModule: String?)
        -> (order: [String], defaultModule: String?) {
        let newOrder = order.map { $0 == oldID ? newID : $0 }
        let newDefault = defaultModule == oldID ? newID : defaultModule
        return (newOrder, newDefault)
    }
}
```

- [ ] **Step 2: Write the test** (append)

```swift
// MARK: - AICodingMigration
let migrated = AICodingMigration.migrate(
    order: ["media", "claude", "calendar"], defaultModule: "claude")
expect(migrated.order == ["media", "ai-coding", "calendar"], "claude id migrated in order")
expect(migrated.defaultModule == "ai-coding", "claude default migrated")
let untouched = AICodingMigration.migrate(order: ["media"], defaultModule: "media")
expect(untouched.order == ["media"], "no claude id → order unchanged")
```

- [ ] **Step 3: Apply migration at startup** — in `SettingsStore` init (or the registry bootstrap that reads `"module.order"`), run the migration once and persist the result. Add:

```swift
// In SettingsStore, called once during init after defaults are available:
func migrateAICodingIfNeeded() {
    let key = "module.order"
    let order = UserDefaults.standard.stringArray(forKey: key) ?? []
    let currentDefault = UserDefaults.standard.string(forKey: "module.default")
    let result = AICodingMigration.migrate(order: order, defaultModule: currentDefault)
    if result.order != order { UserDefaults.standard.set(result.order, forKey: key) }
    if result.defaultModule != currentDefault {
        UserDefaults.standard.set(result.defaultModule, forKey: "module.default")
    }
    // Per-module enabled flag is stored as "module.<id>.enabled"
    // (SettingsStore.isModuleEnabled / setModuleEnabled).
    let oldEnabledKey = "module.claude.enabled"
    if UserDefaults.standard.object(forKey: oldEnabledKey) != nil {
        let value = UserDefaults.standard.bool(forKey: oldEnabledKey)
        UserDefaults.standard.set(value, forKey: "module.ai-coding.enabled")
        UserDefaults.standard.removeObject(forKey: oldEnabledKey)
    }
}
```

Confirmed key names (from `SettingsStore.swift`): default module = `"module.default"` (via `defaultModuleID`); per-module enabled = `"module.<id>.enabled"`; order = `"module.order"`. Call `migrateAICodingIfNeeded()` from the app bootstrap **before** `ModuleRegistry.register(...)` — the natural spot is `SettingsStore.init` (see line ~94 where `defaultModuleID` is loaded) or immediately after the store is constructed and before `ModuleSet`/registry setup.

- [ ] **Step 4: Run checks**

Run: `swift run NotchDeckChecks 2>&1 | tail -3`
Expected: `OK — N checks passed`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: migrate persisted claude module id to ai-coding"
```

---

### Task 9: Per-provider settings toggles

**Files:**
- Modify: `Sources/NotchDeckKit/Settings/SettingsStore.swift` (replace the Task 7 stub)
- Modify: `Sources/NotchDeckKit/Settings/SettingsWindow.swift` (add toggles to the AI Coding pane)

**Interfaces:**
- Consumes: `AICodingModule` (reads toggles in `activeProviders`).
- Produces: `SettingsStore.isAIProviderEnabled(_:) -> Bool` and `SettingsStore.setAIProviderEnabled(_:_:)`, default-true.

- [ ] **Step 1: Replace the stub in `SettingsStore`**

```swift
func isAIProviderEnabled(_ id: String) -> Bool {
    UserDefaults.standard.object(forKey: "aicoding.provider.\(id)") as? Bool ?? true
}
func setAIProviderEnabled(_ id: String, _ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: "aicoding.provider.\(id)")
    objectWillChange.send()
}
```

- [ ] **Step 2: Add toggles in the settings UI** — in `SettingsWindow.swift`, in the section listing modules (grep for the `"AI Coding"` / module toggle rows), add two sub-toggles shown when the AI Coding module is enabled:

```swift
Toggle("Claude Code", isOn: Binding(
    get: { settings.isAIProviderEnabled("claude-code") },
    set: { newValue in
        settings.setAIProviderEnabled("claude-code", newValue)
        AICodingShared.instance?.reloadProviders()
    }))
Toggle("Codex", isOn: Binding(
    get: { settings.isAIProviderEnabled("codex") },
    set: { newValue in
        settings.setAIProviderEnabled("codex", newValue)
        AICodingShared.instance?.reloadProviders()
    }))
```

- [ ] **Step 3: Add `reloadProviders` to `AICodingModule`** (re-arms the watcher with the new root set)

```swift
func reloadProviders() {
    guard watcher != nil else { return }   // only when active
    deactivate()
    activate()
}
```

- [ ] **Step 4: Build + verify toggles persist**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: per-provider AI Coding toggles (Claude Code / Codex)"
```

---

### Task 10: Waiting-approval notification

**Files:**
- Modify: `Sources/NotchDeckKit/Modules/AICoding/AICodingModule.swift` (replace `notifyWaiting` stub)

**Interfaces:**
- Consumes: `sessions` published by the module; `UNUserNotificationCenter`.
- Produces: real `notifyWaiting(_:)` that fires once per session on entry into `.waitingApproval`.

- [ ] **Step 1: Request authorization in `activate()`** (add after `AICodingShared.instance = self`)

```swift
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
```

Add `import UserNotifications` at the top of the file.

- [ ] **Step 2: Replace the `notifyWaiting` stub**

```swift
    private func notifyWaiting(_ found: [AISession]) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let waitingNow = Set(found.filter { $0.status == .waitingApproval }.map(\.id))
        // Clear ids that are no longer waiting so a future wait re-notifies.
        notifiedWaiting.formIntersection(waitingNow)
        for session in found where session.status == .waitingApproval
            && !notifiedWaiting.contains(session.id) {
            notifiedWaiting.insert(session.id)
            let content = UNMutableNotificationContent()
            let provider = session.provider == "codex" ? "Codex" : "Claude Code"
            content.title = "\(provider) waiting for approval"
            content.body = session.projectName
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: "aicoding-\(session.id)", content: content, trigger: nil))
        }
    }
```

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: notify once when an AI coding session waits for approval"
```

---

### Task 11: Best-effort focus terminal

**Files:**
- Create: `Sources/NotchDeckKit/Modules/AICoding/TerminalFocus.swift`
- Modify: `Sources/NotchDeckKit/Modules/AICoding/AICodingModule.swift` (replace `focus` stub)
- Test: `Sources/NotchDeckChecks/main.swift` (append — pure PID-matching helper)

**Interfaces:**
- Produces: `TerminalFocus.terminalBundleIDs` (known terminal bundle ids); `AICodingModule.focus(_:)`.

The mapping from a session to a terminal window is not in the logs. Best effort: find a running terminal app and raise it. If the session has a `cwd`, prefer a terminal whose frontmost is plausible — but since we cannot inspect per-window cwd without Accessibility, we simply raise the most recently active known terminal app. If none is found, do nothing (row stays expanded). No keystrokes.

- [ ] **Step 1: Write the helper**

```swift
// Sources/NotchDeckKit/Modules/AICoding/TerminalFocus.swift
import AppKit

public enum TerminalFocus {
    public static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.github.wez.wezterm",
        "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "com.mitchellh.ghostty",
        "co.zeit.hyper",
    ]

    /// True if the bundle id is a known terminal emulator.
    public static func isTerminal(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return terminalBundleIDs.contains(bundleID)
    }

    /// Raises the most recently active known terminal app, if any.
    @MainActor
    public static func focusFrontmostTerminal() {
        let running = NSWorkspace.shared.runningApplications
            .filter { isTerminal($0.bundleIdentifier) }
        // Prefer the already-active one, else the first running terminal.
        let target = running.first(where: { $0.isActive }) ?? running.first
        target?.activate(options: [.activateAllWindows])
    }
}
```

- [ ] **Step 2: Write the test** (append)

```swift
// MARK: - TerminalFocus
expect(TerminalFocus.isTerminal("com.apple.Terminal") == true, "Terminal.app recognized")
expect(TerminalFocus.isTerminal("com.mitchellh.ghostty") == true, "Ghostty recognized")
expect(TerminalFocus.isTerminal("com.apple.Safari") == false, "Safari not a terminal")
expect(TerminalFocus.isTerminal(nil) == false, "nil bundle id not a terminal")
```

- [ ] **Step 3: Replace the `focus` stub in `AICodingModule`**

```swift
    func focus(_ session: AISession) {
        TerminalFocus.focusFrontmostTerminal()
    }
```

- [ ] **Step 4: Build + checks**

Run: `swift build 2>&1 | tail -3 && swift run NotchDeckChecks 2>&1 | tail -3`
Expected: `Build complete!` and `OK — N checks passed`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: best-effort focus terminal on AI coding session tap"
```

---

### Task 12: End-to-end verification

**Files:** none (verification only).

- [ ] **Step 1: Full check suite**

Run: `swift run NotchDeckChecks 2>&1 | tail -3`
Expected: `OK — N checks passed` with all AI Coding tests included.

- [ ] **Step 2: Bundle + relaunch**

```bash
bash scripts/bundle.sh 2>&1 | tail -3
osascript -e 'quit app "NotchDeck"' 2>/dev/null; sleep 1; open dist/NotchDeck.app
```

- [ ] **Step 3: Drive real sessions and observe**

- Start a Claude Code session and a Codex session in a couple of repos.
- Open the notch → AI Coding tab. Confirm both providers' sessions appear, newest first, with model + last message + token counts.
- Trigger a permission prompt in one CLI (e.g. a command Claude/Codex asks to approve). Within ~4s the collapsed strip should show the "⏳ waiting" glance and a notification should fire once. Approving/denying in the terminal clears the glance on the next FSEvents tick.
- Toggle Codex off in Settings → its sessions disappear; toggle on → they return.

- [ ] **Step 4: Efficiency sanity**

With the module enabled and sessions idle, confirm no busy-looping: `top -pid $(pgrep -f 'MacOS/NotchDeck') -l 3 -stats cpu` stays ~0% between file changes.

- [ ] **Step 5: Final commit (if any verification fixups were made)**

```bash
git add -A
git commit -m "chore: AI Coding end-to-end verification fixups"
```

---

## Self-Review Notes

- **Spec coverage:** provider abstraction (T1,4,5), Codex parsing (T2), waiting detection (T1,2,3), collapsed glance + notification (T7,10), best-effort focus (T11), settings + per-provider toggles (T8,9), module-id migration (T8), FSEvents/no-polling (T6,7), tests (T1–5,8,11), efficiency (T12) — all mapped.
- **Non-goals honored:** no keystroke injection (T11 raises app only), no Cursor, read-only throughout.
- **Type consistency:** `AISession`/`Status`/`AIStatusRule.status(...)` signatures are defined in T1 and consumed unchanged in T4/T5/T7/T10; `AILogTail.tailString` defined in T4 and reused in T5; provider ids `"claude-code"`/`"codex"` used consistently across T4/T5/T7/T9/T10.
- **Integration points confirmed:** persisted keys are `module.order`, `module.default`, `module.<id>.enabled` (SettingsStore.swift). Registration is a stored property `claude` in `ModuleSet` (NotchRootView.swift:22,40,44), constructed in `init(settings:)` where `settings` is in scope — T7 Step 4 gives the exact three edits.
- **Remaining implementer check:** the settings-pane insertion point in `SettingsWindow.swift` (T9 Step 2) is described by grep target rather than line number, since the module-toggle row layout there isn't pinned in this plan.
