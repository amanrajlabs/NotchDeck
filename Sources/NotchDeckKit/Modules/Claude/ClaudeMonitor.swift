import Foundation

/// Parses the tail of a Claude Code session JSONL. Pure and tested.
public enum ClaudeSessionParser {
    public struct TailStats: Equatable, Sendable {
        public var model: String?
        public var inputTokens: Int
        public var outputTokens: Int
        public var cacheReadTokens: Int
        public var assistantMessages: Int
        /// Latest assistant text output, truncated.
        public var preview: String?
        /// True when a tool_use in the tail has no following tool_result.
        public var hasPendingToolUse: Bool

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
    }

    /// Scans JSONL lines; keeps the LAST assistant usage (cumulative context
    /// size) and counts assistant messages in the tail window.
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

    /// "-Users-aman-Desktop-MyStuff-Project" → "Project"
    public static func projectName(fromDirName dirName: String) -> String {
        dirName.split(separator: "-").last.map(String.init) ?? dirName
    }
}
