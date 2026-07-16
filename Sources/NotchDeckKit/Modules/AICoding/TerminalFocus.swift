import AppKit

public enum TerminalFocus {
    public static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.github.wez.wezterm",
        "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "com.mitchellh.ghostty",
        "co.zeit.hyper",
    ]

    /// True if the bundle id is a known terminal emulator.
    public static func isTerminal(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return terminalBundleIDs.contains(bundleID)
    }

    /// Raises the most recently active known terminal app, if any.
    @MainActor
    public static func focusFrontmostTerminal() {
        let running = NSWorkspace.shared.runningApplications
            .filter { isTerminal($0.bundleIdentifier) }
        // Prefer the already-active one, else the first running terminal.
        let target = running.first(where: { $0.isActive }) ?? running.first
        target?.activate(options: [.activateAllWindows])
    }
}
