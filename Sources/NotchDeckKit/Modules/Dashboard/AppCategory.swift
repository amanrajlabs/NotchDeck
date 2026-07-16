import Foundation

/// Coarse bundle-ID → category mapping for screen-time charts.
public enum AppCategory {
    static let table: [String: String] = [
        "com.apple.Safari": "Browsing", "com.google.Chrome": "Browsing",
        "org.mozilla.firefox": "Browsing", "com.brave.Browser": "Browsing",
        "company.thebrowser.Browser": "Browsing", "com.microsoft.edgemac": "Browsing",
        "com.apple.dt.Xcode": "Development", "com.microsoft.VSCode": "Development",
        "com.todesktop.230313mzl4w4u92": "Development", "com.googlecode.iterm2": "Development",
        "com.apple.Terminal": "Development", "com.jetbrains.intellij": "Development",
        "com.tinyspeck.slackmacgap": "Communication", "com.hnc.Discord": "Communication",
        "com.apple.MobileSMS": "Communication", "us.zoom.xos": "Communication",
        "com.apple.mail": "Communication", "com.microsoft.teams2": "Communication",
        "com.spotify.client": "Media", "com.apple.Music": "Media",
        "com.apple.TV": "Media", "com.colliderli.iina": "Media", "org.videolan.vlc": "Media",
        "com.apple.iCal": "Productivity", "com.apple.Notes": "Productivity",
        "com.culturedcode.ThingsMac": "Productivity", "com.apple.reminders": "Productivity",
        "md.obsidian": "Productivity", "notion.id": "Productivity",
    ]

    public static func categorize(_ bundleID: String) -> String {
        table[bundleID] ?? "Other"
    }

    public static func totals(_ slices: [UsageSlice]) -> [(category: String, seconds: TimeInterval)] {
        var buckets: [String: TimeInterval] = [:]
        for slice in slices where slice.bundleID != "other" {
            buckets[categorize(slice.bundleID), default: 0] += slice.seconds
        }
        return buckets.sorted { $0.value > $1.value }.map { (category: $0.key, seconds: $0.value) }
    }
}
