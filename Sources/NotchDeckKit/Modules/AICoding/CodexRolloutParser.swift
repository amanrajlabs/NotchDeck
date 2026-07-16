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
