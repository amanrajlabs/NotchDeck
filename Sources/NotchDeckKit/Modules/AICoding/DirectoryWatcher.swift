// Sources/NotchDeckKit/Modules/AICoding/DirectoryWatcher.swift
import CoreServices
import Foundation

/// Watches directory trees via FSEvents and fires onChange (coalesced) on the
/// main queue. No polling.
public final class DirectoryWatcher {
    private let paths: [String]
    private let onChange: @Sendable () -> Void
    private var stream: FSEventStreamRef?

    public init(paths: [String], onChange: @escaping @Sendable () -> Void) {
        self.paths = paths
        self.onChange = onChange
    }

    public func start() {
        guard stream == nil, !paths.isEmpty else { return }
        let info = Unmanaged.passRetained(Box(onChange)).toOpaque()
        var context = FSEventStreamContext(
            version: 0, info: info, retain: nil,
            release: { ptr in ptr.map { Unmanaged<Box>.fromOpaque($0).release() } },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            box.fire()
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.4,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)) else {
            Unmanaged<Box>.fromOpaque(info).release()
            return
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private final class Box {
        let onChange: @Sendable () -> Void
        init(_ onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
        func fire() { onChange() }
    }
}
