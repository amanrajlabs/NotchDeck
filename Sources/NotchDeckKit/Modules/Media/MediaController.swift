import AppKit
import Combine

public enum PlayerApp: String, CaseIterable, Sendable {
    case spotify = "com.spotify.client"
    case music = "com.apple.Music"

    var scriptName: String {
        switch self {
        case .spotify: "Spotify"
        case .music: "Music"
        }
    }

    var notificationName: String {
        switch self {
        case .spotify: "com.spotify.client.PlaybackStateChanged"
        case .music: "com.apple.Music.playerInfo"
        }
    }
}

public struct TrackInfo: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    /// Seconds.
    public var duration: TimeInterval
    public var isPlaying: Bool
    public var player: PlayerApp
}

/// Pure mapping from a player's DistributedNotification payload. Tested.
public enum MediaStateMapper {
    public static func trackInfo(from userInfo: [AnyHashable: Any], player: PlayerApp) -> TrackInfo? {
        guard let state = userInfo["Player State"] as? String,
              state == "Playing" || state == "Paused" else { return nil }
        let durationMS: Double
        switch player {
        case .spotify: durationMS = doubleValue(userInfo["Duration"]) ?? 0
        case .music: durationMS = doubleValue(userInfo["Total Time"]) ?? 0
        }
        return TrackInfo(
            title: userInfo["Name"] as? String ?? "",
            artist: userInfo["Artist"] as? String ?? "",
            album: userInfo["Album"] as? String ?? "",
            duration: durationMS / 1000.0,
            isPlaying: state == "Playing",
            player: player
        )
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        switch any {
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s)
        default: nil
        }
    }
}

@MainActor
final class MediaController: ObservableObject {
    @Published private(set) var track: TrackInfo?
    @Published private(set) var artwork: NSImage?
    @Published var position: TimeInterval = 0
    /// Views set this so position polling only runs while visible.
    @Published var isPanelVisible = false {
        didSet { updatePositionTimer() }
    }

    private var observers: [NSObjectProtocol] = []
    private var positionTimer: Timer?
    private var scriptCache: [String: NSAppleScript] = [:]
    private var artworkTask: Task<Void, Never>?

    func activate() {
        let center = DistributedNotificationCenter.default()
        for player in PlayerApp.allCases {
            let observer = center.addObserver(
                forName: Notification.Name(player.notificationName),
                object: nil, queue: .main
            ) { note in
                // DistributedNotification payloads are plists (Sendable in
                // practice); extract before hopping to the main actor.
                let info = MediaStateMapper.trackInfo(from: note.userInfo ?? [:], player: player)
                MainActor.assumeIsolated {
                    MediaControllerShared.instance?.handle(player: player, info: info)
                }
            }
            observers.append(observer)
        }
        MediaControllerShared.instance = self
        refreshFromRunningPlayers()
    }

    func deactivate() {
        let center = DistributedNotificationCenter.default()
        observers.forEach(center.removeObserver(_:))
        observers = []
        positionTimer?.invalidate()
        positionTimer = nil
        artworkTask?.cancel()
        track = nil
        artwork = nil
    }

    // MARK: Controls

    func playPause() { command("playpause") }
    func nextTrack() { command("next track") }
    func previousTrack() { command("previous track") }

    func seek(to seconds: TimeInterval) {
        guard let player = track?.player else { return }
        position = seconds
        runScript("tell application \"\(player.scriptName)\" to set player position to \(Int(seconds))")
    }

    private func command(_ verb: String) {
        guard let player = track?.player ?? runningPlayer() else { return }
        runScript("tell application \"\(player.scriptName)\" to \(verb)")
    }

    // MARK: State

    private func handle(player: PlayerApp, info: TrackInfo?) {
        guard let info else {
            if track?.player == player {
                track = nil
                artwork = nil
                updatePositionTimer()
            }
            return
        }
        let trackChanged = info.title != track?.title || info.player != track?.player
        track = info
        if trackChanged {
            artwork = nil
            position = 0
            fetchArtwork(for: info)
        }
        syncPosition()
        updatePositionTimer()
    }

    private func refreshFromRunningPlayers() {
        for player in PlayerApp.allCases where Self.isRunning(player) {
            let source = """
            tell application "\(player.scriptName)"
                if player state is stopped then return "stopped"
                set t to current track
                return (player state as text) & "||" & (name of t) & "||" & (artist of t) & "||" & (album of t) & "||" & (duration of t as text) & "||" & (player position as text)
            end tell
            """
            guard let descriptor = runScript(source),
                  let raw = descriptor.stringValue, raw != "stopped" else { continue }
            let parts = raw.components(separatedBy: "||")
            guard parts.count >= 6 else { continue }
            let rawDuration = Double(parts[4].replacingOccurrences(of: ",", with: ".")) ?? 0
            // Spotify reports duration in ms, Music in seconds.
            let duration = player == .spotify ? rawDuration / 1000.0 : rawDuration
            let info = TrackInfo(
                title: parts[1], artist: parts[2], album: parts[3],
                duration: duration,
                isPlaying: parts[0].lowercased().contains("playing"),
                player: player
            )
            track = info
            position = Double(parts[5].replacingOccurrences(of: ",", with: ".")) ?? 0
            fetchArtwork(for: info)
            updatePositionTimer()
            if info.isPlaying { break }
        }
    }

    private func runningPlayer() -> PlayerApp? {
        PlayerApp.allCases.first(where: Self.isRunning)
    }

    private static func isRunning(_ player: PlayerApp) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: player.rawValue).isEmpty
    }

    // MARK: Artwork

    private func fetchArtwork(for info: TrackInfo) {
        artworkTask?.cancel()
        switch info.player {
        case .spotify:
            guard let descriptor = runScript("tell application \"Spotify\" to return artwork url of current track"),
                  let urlString = descriptor.stringValue,
                  let url = URL(string: urlString) else { return }
            artworkTask = Task { [weak self] in
                guard let (data, _) = try? await URLSession.shared.data(from: url),
                      !Task.isCancelled else { return }
                self?.artwork = NSImage(data: data)
            }
        case .music:
            guard let descriptor = runScript("tell application \"Music\" to return data of artwork 1 of current track"),
                  descriptor.data.count > 16 else { return }
            artwork = NSImage(data: descriptor.data)
        }
    }

    // MARK: Position polling (only while the panel shows the scrubber)

    private func updatePositionTimer() {
        let shouldRun = isPanelVisible && track?.isPlaying == true
        if shouldRun, positionTimer == nil {
            positionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                MainActor.assumeIsolated { MediaControllerShared.instance?.tick() }
            }
        } else if !shouldRun {
            positionTimer?.invalidate()
            positionTimer = nil
        }
    }

    private func tick() {
        guard track?.isPlaying == true else { return }
        if isPanelVisible {
            syncPosition()
        } else {
            position += 1
        }
    }

    private func syncPosition() {
        guard let player = track?.player,
              let descriptor = runScript("tell application \"\(player.scriptName)\" to return player position as text"),
              let raw = descriptor.stringValue else { return }
        position = Double(raw.replacingOccurrences(of: ",", with: ".")) ?? position
    }

    // MARK: AppleScript

    @discardableResult
    private func runScript(_ source: String) -> NSAppleEventDescriptor? {
        let script: NSAppleScript
        if let cached = scriptCache[source] {
            script = cached
        } else {
            guard let fresh = NSAppleScript(source: source) else { return nil }
            scriptCache[source] = fresh
            script = fresh
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil ? result : nil
    }
}

@MainActor
enum MediaControllerShared {
    weak static var instance: MediaController?
}
