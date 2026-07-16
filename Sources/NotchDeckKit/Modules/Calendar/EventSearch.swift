import Foundation

/// Pure substring matcher for filtering loaded items (calendar events, etc.)
/// by title. Case- and diacritic-insensitive; an empty query matches
/// everything. Tested.
public enum EventSearch {
    public static func matches(query: String, in fields: [String?]) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        return fields.compactMap { $0 }.contains {
            $0.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
