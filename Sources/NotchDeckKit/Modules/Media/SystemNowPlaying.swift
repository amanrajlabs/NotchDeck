import AppKit
import Foundation

/// Now-playing state for any app (browsers included), fed by the vendored
/// mediaremote-adapter helper.
public struct SystemNowPlaying: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    /// Seconds.
    public var duration: TimeInterval
    /// Seconds, at the moment the event was emitted.
    public var elapsed: TimeInterval
    public var playing: Bool
    public var bundleID: String?
    public var artworkBase64: String?

    public init(
        title: String, artist: String, album: String,
        duration: TimeInterval, elapsed: TimeInterval, playing: Bool,
        bundleID: String?, artworkBase64: String?
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.elapsed = elapsed
        self.playing = playing
        self.bundleID = bundleID
        self.artworkBase64 = artworkBase64
    }
}

/// Parses the adapter's stream protocol: JSON lines shaped
/// `{"type":"data","diff":Bool,"payload":{...}}`. In diff mode only changed
/// keys arrive (NSNull clears a key), so the accumulator merges into the
/// previous payload. Pure and tested.
public struct SystemNowPlayingAccumulator {
    private var payload: [String: Any] = [:]

    public init() {}

    /// Feed one line; returns the new state (nil when the line isn't a data
    /// line). An empty payload after merge means "nothing playing".
    public mutating func ingest(line: String) -> SystemNowPlaying?? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let envelope = object as? [String: Any],
              envelope["type"] as? String == "data",
              let incoming = envelope["payload"] as? [String: Any] else {
            return nil
        }
        let isDiff = (envelope["diff"] as? Bool) ?? false
        if isDiff {
            for (key, value) in incoming {
                if value is NSNull {
                    payload.removeValue(forKey: key)
                } else {
                    payload[key] = value
                }
            }
        } else {
            payload = incoming
        }
        return .some(Self.state(from: payload))
    }

    static func state(from payload: [String: Any]) -> SystemNowPlaying? {
        guard let title = payload["title"] as? String, !title.isEmpty else {
            return nil
        }
        return SystemNowPlaying(
            title: title,
            artist: payload["artist"] as? String ?? "",
            album: payload["album"] as? String ?? "",
            duration: doubleValue(payload["duration"]) ?? 0,
            elapsed: doubleValue(payload["elapsedTime"]) ?? 0,
            playing: (payload["playing"] as? Bool)
                ?? ((payload["playing"] as? NSNumber)?.boolValue ?? false),
            bundleID: payload["bundleIdentifier"] as? String,
            artworkBase64: payload["artworkData"] as? String
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

/// Runs the perl-hosted adapter as a child process and streams events.
@MainActor
final class SystemMediaSource {
    enum Command: Int {
        case play = 0, pause = 1, toggle = 2, next = 4, previous = 5
    }

    private var process: Process?
    private var accumulator = SystemNowPlayingAccumulator()
    private var buffer = Data()
    private var onState: ((SystemNowPlaying?) -> Void)?
    private var restartCount = 0
    private var stopped = true

    private static var scriptURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("mediaremote-adapter.pl")
    }
    private static var frameworkURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("MediaRemoteAdapter.framework")
    }

    var isAvailable: Bool {
        guard let script = Self.scriptURL, let framework = Self.frameworkURL else { return false }
        return FileManager.default.fileExists(atPath: script.path)
            && FileManager.default.fileExists(atPath: framework.path)
    }

    func start(onState: @escaping (SystemNowPlaying?) -> Void) {
        guard isAvailable, process == nil else { return }
        self.onState = onState
        stopped = false
        launch()
    }

    func stop() {
        stopped = true
        onState = nil
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
    }

    private func launch() {
        guard let script = Self.scriptURL, let framework = Self.frameworkURL else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, framework.path, "stream", "--debounce=150"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.consume(chunk)
            }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleTermination()
            }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            self.process = nil
        }
    }

    private func handleTermination() {
        process = nil
        guard !stopped else { return }
        restartCount += 1
        guard restartCount <= 3 else { return } // stream unsupported; give up quietly
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !self.stopped else { return }
            self.launch()
        }
    }

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            if let result = accumulator.ingest(line: line) {
                onState?(result)
            }
        }
    }

    // MARK: One-shot commands (short-lived helper invocations)

    func send(_ command: Command) {
        runOneShot(["send", String(command.rawValue)])
    }

    func seek(to seconds: TimeInterval) {
        runOneShot(["seek", String(Int(seconds * 1_000_000))])
    }

    private func runOneShot(_ arguments: [String]) {
        guard let script = Self.scriptURL, let framework = Self.frameworkURL else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, framework.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
