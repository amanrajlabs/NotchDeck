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
