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
