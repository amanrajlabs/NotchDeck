import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageFormat: String, CaseIterable, Sendable {
    case png, jpeg, heic

    var utType: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        default: rawValue
        }
    }
}

public enum DropActionError: LocalizedError {
    case noFiles
    case processFailed(String)
    case notAnImage(String)

    public var errorDescription: String? {
        switch self {
        case .noFiles: "No files to act on"
        case .processFailed(let tool): "\(tool) failed"
        case .notAnImage(let name): "\(name) is not a readable image"
        }
    }
}

/// File operations behind the drop grid. Pure enough to unit test.
public enum DropActionRunner {
    /// Zips files next to the first one; returns the archive URL.
    public static func zip(_ urls: [URL]) throws -> URL {
        guard let first = urls.first else { throw DropActionError.noFiles }
        let destDir = first.deletingLastPathComponent()
        let baseName = urls.count == 1 ? first.deletingPathExtension().lastPathComponent : "Archive"
        let dest = uniqueURL(in: destDir, base: baseName, ext: "zip")

        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        for url in urls {
            try fm.copyItem(at: url, to: staging.appendingPathComponent(url.lastPathComponent))
        }

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--sequesterRsrc", staging.path, dest.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw DropActionError.processFailed("ditto") }
        return dest
    }

    /// Converts an image, writing the result next to the source; returns the new URL.
    public static func convert(_ url: URL, to format: ImageFormat) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw DropActionError.notAnImage(url.lastPathComponent)
        }
        let dest = uniqueURL(
            in: url.deletingLastPathComponent(),
            base: url.deletingPathExtension().lastPathComponent,
            ext: format.fileExtension
        )
        guard let destination = CGImageDestinationCreateWithURL(
            dest as CFURL, format.utType.identifier as CFString, 1, nil
        ) else { throw DropActionError.processFailed("ImageIO") }
        CGImageDestinationAddImageFromSource(destination, source, 0, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw DropActionError.processFailed("ImageIO")
        }
        return dest
    }

    public static func move(_ urls: [URL], to directory: URL) throws {
        for url in urls {
            try FileManager.default.moveItem(
                at: url,
                to: uniqueDestination(for: url, in: directory)
            )
        }
    }

    public static func copy(_ urls: [URL], to directory: URL) throws {
        for url in urls {
            try FileManager.default.copyItem(
                at: url,
                to: uniqueDestination(for: url, in: directory)
            )
        }
    }

    /// Extracts an archive into a unique sibling folder; returns the folder.
    public static func unzip(_ url: URL) throws -> URL {
        let parent = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        var destDir = parent.appendingPathComponent(base, isDirectory: true)
        var counter = 2
        while FileManager.default.fileExists(atPath: destDir.path) {
            destDir = parent.appendingPathComponent("\(base) \(counter)", isDirectory: true)
            counter += 1
        }
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", url.path, destDir.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw DropActionError.processFailed("ditto") }
        return destDir
    }

    public static func trash(_ urls: [URL]) throws {
        for url in urls {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    /// `/Volumes/Name/…` → `/Volumes/Name`. Anything else is not ejectable.
    public static func volumeRoot(for url: URL) -> URL? {
        let parts = url.pathComponents
        guard parts.count >= 3, parts[0] == "/", parts[1] == "Volumes" else { return nil }
        return URL(fileURLWithPath: "/Volumes/\(parts[2])")
    }

    public static func iCloudDriveURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
    }

    public static func saveToICloud(_ urls: [URL]) throws {
        let drive = iCloudDriveURL()
        guard FileManager.default.fileExists(atPath: drive.path) else {
            throw DropActionError.processFailed("iCloud Drive")
        }
        try copy(urls, to: drive)
    }

    // MARK: Naming

    public static func uniqueURL(in directory: URL, base: String, ext: String) -> URL {
        var candidate = directory.appendingPathComponent("\(base).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    private static func uniqueDestination(for url: URL, in directory: URL) -> URL {
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        if ext.isEmpty {
            var candidate = directory.appendingPathComponent(base)
            var counter = 2
            while FileManager.default.fileExists(atPath: candidate.path) {
                candidate = directory.appendingPathComponent("\(base) \(counter)")
                counter += 1
            }
            return candidate
        }
        return uniqueURL(in: directory, base: base, ext: ext)
    }
}
