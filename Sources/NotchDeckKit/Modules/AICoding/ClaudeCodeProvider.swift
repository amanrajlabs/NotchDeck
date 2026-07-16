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
