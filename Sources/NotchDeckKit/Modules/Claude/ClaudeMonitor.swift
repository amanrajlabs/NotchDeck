import AppKit
import SwiftUI

public struct ClaudeSession: Identifiable, Equatable, Sendable {
    public var id: String
    public var projectName: String
    public var lastActivity: Date
    public var model: String?
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var assistantMessages: Int

    public var isActive: Bool { Date().timeIntervalSince(lastActivity) < 120 }

    public init(id: String, projectName: String, lastActivity: Date, model: String?,
                inputTokens: Int, outputTokens: Int, cacheReadTokens: Int, assistantMessages: Int) {
        self.id = id
        self.projectName = projectName
        self.lastActivity = lastActivity
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.assistantMessages = assistantMessages
    }
}

/// Parses the tail of a Claude Code session JSONL. Pure and tested.
public enum ClaudeSessionParser {
    public struct TailStats: Equatable, Sendable {
        public var model: String?
        public var inputTokens: Int
        public var outputTokens: Int
        public var cacheReadTokens: Int
        public var assistantMessages: Int

        public init(model: String? = nil, inputTokens: Int = 0, outputTokens: Int = 0,
                    cacheReadTokens: Int = 0, assistantMessages: Int = 0) {
            self.model = model
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheReadTokens = cacheReadTokens
            self.assistantMessages = assistantMessages
        }
    }

    /// Scans JSONL lines; keeps the LAST assistant usage (cumulative context
    /// size) and counts assistant messages in the tail window.
    public static func parse(tail: String) -> TailStats {
        var stats = TailStats()
        for line in tail.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  root["type"] as? String == "assistant",
                  let message = root["message"] as? [String: Any] else { continue }
            stats.assistantMessages += 1
            if let model = message["model"] as? String { stats.model = model }
            if let usage = message["usage"] as? [String: Any] {
                stats.inputTokens = (usage["input_tokens"] as? NSNumber)?.intValue ?? stats.inputTokens
                stats.outputTokens = (usage["output_tokens"] as? NSNumber)?.intValue ?? stats.outputTokens
                stats.cacheReadTokens = (usage["cache_read_input_tokens"] as? NSNumber)?.intValue ?? stats.cacheReadTokens
            }
        }
        return stats
    }

    /// "-Users-aman-Desktop-MyStuff-Project" → "Project"
    public static func projectName(fromDirName dirName: String) -> String {
        dirName.split(separator: "-").last.map(String.init) ?? dirName
    }
}

// MARK: - Module

@MainActor
final class ClaudeModule: NotchModule, ObservableObject {
    static let moduleID = "claude"
    let id = ClaudeModule.moduleID
    let name = "Claude Code"
    let icon = "sparkles"
    let hasPanel = true

    @Published private(set) var sessions: [ClaudeSession] = []
    private var timer: Timer?

    func activate() {}
    func deactivate() { stopRefreshing() }

    func panelView() -> AnyView { AnyView(ClaudePanelView(module: self)) }

    func startRefreshing() {
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { ClaudeModuleShared.instance?.refresh() }
        }
        ClaudeModuleShared.instance = self
    }

    func stopRefreshing() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        Task.detached(priority: .utility) {
            let found = Self.scan()
            await MainActor.run {
                ClaudeModuleShared.instance?.sessions = found
            }
        }
    }

    nonisolated static func scan() -> [ClaudeSession] {
        let fm = FileManager.default
        let projectsDir = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects")
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: nil
        ) else { return [] }

        var sessions: [ClaudeSession] = []
        let cutoff = Date().addingTimeInterval(-6 * 3600)
        for dir in projectDirs {
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }
            // Newest recently-touched session per project.
            let recent = files
                .filter { $0.pathExtension == "jsonl" }
                .compactMap { url -> (URL, Date)? in
                    guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate, modified > cutoff else { return nil }
                    return (url, modified)
                }
                .max { $0.1 < $1.1 }
            guard let (file, modified) = recent else { continue }
            guard let tail = tailString(of: file, bytes: 64 * 1024) else { continue }
            let stats = ClaudeSessionParser.parse(tail: tail)
            sessions.append(ClaudeSession(
                id: file.path,
                projectName: ClaudeSessionParser.projectName(fromDirName: dir.lastPathComponent),
                lastActivity: modified,
                model: stats.model,
                inputTokens: stats.inputTokens,
                outputTokens: stats.outputTokens,
                cacheReadTokens: stats.cacheReadTokens,
                assistantMessages: stats.assistantMessages
            ))
        }
        return sessions.sorted { $0.lastActivity > $1.lastActivity }
    }

    nonisolated private static func tailString(of url: URL, bytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }
        guard let text = String(data: data, encoding: .utf8) else {
            // A mid-character cut can break UTF-8; retry lossily.
            return String(decoding: data, as: UTF8.self)
        }
        return text
    }
}

@MainActor
enum ClaudeModuleShared {
    weak static var instance: ClaudeModule?
}

struct ClaudePanelView: View {
    @ObservedObject var module: ClaudeModule

    var body: some View {
        Group {
            if module.sessions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("No recent Claude Code sessions")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(module.sessions) { session in
                            SessionRow(session: session)
                        }
                    }
                }
            }
        }
        .onAppear { module.startRefreshing() }
        .onDisappear { module.stopRefreshing() }
    }
}

struct SessionRow: View {
    let session: ClaudeSession

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(session.isActive ? Color.green : Color.gray.opacity(0.5))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.projectName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let model = session.model {
                        Text(model.replacingOccurrences(of: "claude-", with: ""))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    Text(session.lastActivity, style: .relative)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(Self.compact(session.inputTokens + session.cacheReadTokens)) in · \(Self.compact(session.outputTokens)) out")
                    .font(.system(size: 10).monospacedDigit())
                Text("\(session.assistantMessages) msgs in window")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
    }

    static func compact(_ n: Int) -> String {
        switch n {
        case 1_000_000...: String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: String(format: "%.1fk", Double(n) / 1_000)
        default: "\(n)"
        }
    }
}
