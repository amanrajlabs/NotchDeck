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
