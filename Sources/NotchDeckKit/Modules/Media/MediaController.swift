import AppKit
import Combine

public enum PlayerApp: String, CaseIterable, Sendable {
    case spotify = "com.spotify.client"
    case music = "com.apple.Music"
    /// Anything surfaced via system now-playing (browsers, VLC, …),
    /// controlled through the MediaRemote helper instead of AppleScript.
    case system = "system"

    /// Players with a rich AppleScript interface.
    static let scriptable: [PlayerApp] = [.spotify, .music]

    var scriptName: String? {
        switch self {
        case .spotify: "Spotify"
        case .music: "Music"
        case .system: nil
        }
    }

    var notificationName: String? {
        switch self {
        case .spotify: "com.spotify.client.PlaybackStateChanged"
        case .music: "com.apple.Music.playerInfo"
        case .system: nil
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
    /// Display name of the source app for system tracks ("Chrome", …).
    public var appName: String?

    public init(
        title: String, artist: String, album: String, duration: TimeInterval,
        isPlaying: Bool, player: PlayerApp, appName: String? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.isPlaying = isPlaying
        self.player = player
        self.appName = appName
    }
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
        case .system: return nil // system tracks come from the stream, not plists
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
    private let systemSource = SystemMediaSource()

    func activate() {
        let center = DistributedNotificationCenter.default()
        for player in PlayerApp.scriptable {
            guard let name = player.notificationName else { continue }
            let observer = center.addObserver(
                forName: Notification.Name(name),
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
        systemSource.start { [weak self] state in
            self?.handleSystem(state)
        }
        refreshFromRunningPlayers()
    }

    func deactivate() {
        let center = DistributedNotificationCenter.default()
        observers.forEach(center.removeObserver(_:))
        observers = []
        systemSource.stop()
        positionTimer?.invalidate()
        positionTimer = nil
        artworkTask?.cancel()
        track = nil
        artwork = nil
    }

    // MARK: Controls

    func playPause() {
        if track?.player == .system {
            systemSource.send(.toggle)
        } else {
            command("playpause")
        }
    }

    func nextTrack() {
        if track?.player == .system {
            systemSource.send(.next)
        } else {
            command("next track")
        }
    }

    func previousTrack() {
        if track?.player == .system {
            systemSource.send(.previous)
        } else {
            command("previous track")
        }
    }

    func seek(to seconds: TimeInterval) {
        guard let player = track?.player else { return }
        position = seconds
        if player == .system {
            systemSource.seek(to: seconds)
        } else if let scriptName = player.scriptName {
            runScript("tell application \"\(scriptName)\" to set player position to \(Int(seconds))")
        }
    }

    private func command(_ verb: String) {
        guard let player = track?.player ?? runningPlayer(),
              let scriptName = player.scriptName else { return }
        runScript("tell application \"\(scriptName)\" to \(verb)")
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

    /// System now-playing events (browsers and everything else). Spotify and
    /// Music payloads are ignored here — their richer AppleScript path owns
    /// them.
    private func handleSystem(_ state: SystemNowPlaying?) {
        guard let state else {
            if track?.player == .system {
                track = nil
                artwork = nil
                updatePositionTimer()
            }
            return
        }
        if let bundleID = state.bundleID,
           PlayerApp(rawValue: bundleID) != nil {
            return
        }
        let appName = state.bundleID.flatMap { id in
            NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .first?.localizedName
        }
        let info = TrackInfo(
            title: state.title, artist: state.artist, album: state.album,
            duration: state.duration, isPlaying: state.playing,
            player: .system, appName: appName
        )
        let trackChanged = info.title != track?.title || track?.player != .system
        track = info
        position = state.elapsed
        if trackChanged { artwork = nil }
        if let b64 = state.artworkBase64, let data = Data(base64Encoded: b64) {
            artwork = NSImage(data: data)
        }
        updatePositionTimer()
    }

    private func refreshFromRunningPlayers() {
        for player in PlayerApp.scriptable where Self.isRunning(player) {
            let source = """
            tell application "\(player.scriptName ?? "")"
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
        case .system:
            break // artwork arrives inline in the stream payload
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
        if isPanelVisible, track?.player != .system {
            syncPosition()
        } else {
            // System tracks extrapolate; the stream corrects on state changes.
            position += 1
        }
    }

    private func syncPosition() {
        guard let scriptName = track?.player.scriptName,
              let descriptor = runScript("tell application \"\(scriptName)\" to return player position as text"),
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
