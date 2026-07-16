import Foundation

public struct TrashedTask: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var deletedAt: Date

    public init(id: String, title: String, deletedAt: Date) {
        self.id = id
        self.title = title
        self.deletedAt = deletedAt
    }
}

public enum TaskTrash {
    public static func pruned(
        _ entries: [TrashedTask], now: Date, retentionDays: Int
    ) -> [TrashedTask] {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        return entries.filter { $0.deletedAt > cutoff }
    }
}
