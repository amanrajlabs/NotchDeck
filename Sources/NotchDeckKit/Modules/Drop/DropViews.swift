import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class DropModule: NotchModule, ObservableObject {
    static let moduleID = "drop"
    let id = DropModule.moduleID
    let name = "Shelf"
    let icon = "tray.and.arrow.down.fill"
    let hasPanel = true
    var preferredHeight: CGFloat { 210 }
    /// Copy vs move mode for the folder action.
    @Published var moveMode = false

    @Published var pendingFiles: [URL] = []
    @Published var statusMessage: String?
    /// Whether the second row of the drop grid is revealed. Transient — reset on deactivate/clear.
    @Published var gridExpanded = false
    private var statusTask: Task<Void, Never>?

    func activate() {
        DropModuleShared.instance = self
    }

    func deactivate() {
        pendingFiles = []
        statusMessage = nil
        gridExpanded = false
    }

    func panelView() -> AnyView { AnyView(ShelfView(module: self)) }

    func headerBadge() -> AnyView? {
        AnyView(
            HStack(spacing: 5) {
                Image(systemName: "envelope.open")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text("\(pendingFiles.count) item\(pendingFiles.count == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        )
    }

    func headerActions() -> AnyView? {
        AnyView(ShelfHeaderActions(module: self))
    }

    func addPending(_ providers: [NSItemProvider]) {
        let box = ProviderBox(providers: providers)
        Task { [weak self] in
            let urls = await FileDropLoader.urls(from: box)
            guard let self, !urls.isEmpty else { return }
            self.pendingFiles.append(contentsOf: urls)
        }
    }

    func run(_ action: DropGridAction, on urls: [URL]) {
        guard !urls.isEmpty else {
            showStatus("Drop a file first")
            return
        }
        switch action {
        case .shelf:
            pendingFiles.append(contentsOf: urls)
            showStatus("Added to shelf")
        case .unzip:
            runOffMain("Unzipping…") {
                for url in urls { _ = try DropActionRunner.unzip(url) }
                return "Unzipped"
            }
        case .music:
            let music = URL(fileURLWithPath: "/System/Applications/Music.app")
            NSWorkspace.shared.open(urls, withApplicationAt: music,
                                    configuration: NSWorkspace.OpenConfiguration())
            clearPending()
        case .trashOrEject:
            let volumes = urls.compactMap { DropActionRunner.volumeRoot(for: $0) }
            if !volumes.isEmpty {
                for volume in Set(volumes) {
                    try? NSWorkspace.shared.unmountAndEjectDevice(at: volume)
                }
                showStatus("Ejected")
                clearPending()
            } else {
                runOffMain("Trashing…") {
                    try DropActionRunner.trash(urls)
                    return "Moved to Trash"
                }
            }
        case .icloud:
            runOffMain("Saving to iCloud…") {
                try DropActionRunner.saveToICloud(urls)
                return "Saved to iCloud Drive"
            }
        case .expand:
            gridExpanded.toggle()
        case .airdrop:
            if let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) {
                service.perform(withItems: urls)
                clearPending()
            } else {
                showStatus("AirDrop unavailable")
            }
        case .zip:
            runOffMain("Zipping…") {
                let archive = try DropActionRunner.zip(urls)
                return "Zipped → \(archive.lastPathComponent)"
            }
        case .convert(let format):
            runOffMain("Converting…") {
                for url in urls {
                    _ = try DropActionRunner.convert(url, to: format)
                }
                return "Converted to \(format.rawValue.uppercased())"
            }
        case .move, .copy:
            chooseFolder { [weak self] folder in
                guard let self, let folder else { return }
                let isMove = action == .move
                self.runOffMain(isMove ? "Moving…" : "Copying…") {
                    if isMove {
                        try DropActionRunner.move(urls, to: folder)
                        return "Moved to \(folder.lastPathComponent)"
                    } else {
                        try DropActionRunner.copy(urls, to: folder)
                        return "Copied to \(folder.lastPathComponent)"
                    }
                }
            }
        case .openWith:
            openWithMenu(urls: urls)
        }
    }

    /// File ops can be slow (zipping a folder); never block the UI thread.
    private func runOffMain(
        _ progressMessage: String,
        _ work: @escaping @Sendable () throws -> String
    ) {
        showStatus(progressMessage)
        Task.detached(priority: .userInitiated) {
            let outcome: String
            do {
                outcome = try work()
            } catch {
                outcome = error.localizedDescription
            }
            await MainActor.run {
                guard let self = DropModuleShared.instance else { return }
                self.showStatus(outcome)
                self.clearPending()
            }
        }
    }

    func clearPending() {
        pendingFiles = []
        gridExpanded = false
    }

    /// Entry point for a drop landing directly on a grid tile (each tile is its own drop target).
    func handleGridDrop(_ action: DropGridAction, providers: [NSItemProvider]) {
        let box = ProviderBox(providers: providers)
        Task { [weak self] in
            let urls = await FileDropLoader.urls(from: box)
            guard let self, !urls.isEmpty else { return }
            self.run(action, on: urls)
        }
    }

    private func showStatus(_ message: String) {
        statusMessage = message
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.statusMessage = nil
        }
    }

    private func chooseFolder(_ completion: @escaping @MainActor (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            MainActor.assumeIsolated {
                completion(response == .OK ? panel.url : nil)
            }
        }
    }

    private func openWithMenu(urls: [URL]) {
        guard let first = urls.first else { return }
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: first)
        let menu = NSMenu()
        for app in apps.prefix(12) {
            let name = FileManager.default.displayName(atPath: app.path)
            let item = NSMenuItem(title: name, action: #selector(OpenWithTarget.open(_:)), keyEquivalent: "")
            item.representedObject = OpenWithPayload(appURL: app, fileURLs: urls)
            item.target = OpenWithTarget.shared
            item.image = NSWorkspace.shared.icon(forFile: app.path)
            item.image?.size = NSSize(width: 16, height: 16)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

final class OpenWithPayload: NSObject {
    let appURL: URL
    let fileURLs: [URL]
    init(appURL: URL, fileURLs: [URL]) {
        self.appURL = appURL
        self.fileURLs = fileURLs
    }
}

@MainActor
final class OpenWithTarget: NSObject {
    static let shared = OpenWithTarget()

    @objc func open(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? OpenWithPayload else { return }
        NSWorkspace.shared.open(
            payload.fileURLs,
            withApplicationAt: payload.appURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}

/// NSItemProvider is documented as thread-safe but predates Sendable.
struct ProviderBox: @unchecked Sendable {
    let providers: [NSItemProvider]
}

enum FileDropLoader {
    static func urls(from box: ProviderBox) async -> [URL] {
        var urls: [URL] = []
        for provider in box.providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let url: URL? = await withCheckedContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    if let data = item as? Data {
                        continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                    } else if let url = item as? URL {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
            if let url { urls.append(url) }
        }
        return urls
    }
}

// MARK: - Views

enum DropGridAction: Hashable {
    case shelf
    case airdrop
    case zip
    case unzip
    case convert(ImageFormat)
    case move
    case copy
    case openWith
    case music
    case trashOrEject
    case icloud
    case expand

    var title: String {
        switch self {
        case .shelf: "Shelf"
        case .airdrop: "AirDrop"
        case .zip: "Zip"
        case .unzip: "Unzip"
        case .convert(let f): f.rawValue.uppercased()
        case .move: "Move…"
        case .copy: "Copy…"
        case .openWith: "Open With"
        case .music: "Music"
        case .trashOrEject: "Trash / Eject"
        case .icloud: "iCloud"
        case .expand: "Expand"
        }
    }

    var icon: String {
        switch self {
        case .shelf: "tray.and.arrow.down.fill"
        case .airdrop: "wifi"
        case .zip: "doc.zipper"
        case .unzip: "shippingbox.and.arrow.backward"
        case .convert: "photo.on.rectangle.angled"
        case .move: "folder"
        case .copy: "doc.on.doc"
        case .openWith: "arrow.up.forward.app"
        case .music: "music.note"
        case .trashOrEject: "trash"
        case .icloud: "icloud.and.arrow.up"
        case .expand: "chevron.down.circle"
        }
    }

    static let firstRow: [DropGridAction] = [.shelf, .airdrop, .zip, .convert(.png), .expand]
    static let secondRow: [DropGridAction] = [.unzip, .move, .copy, .openWith, .music, .trashOrEject, .icloud]
}

struct ShelfHeaderActions: View {
    @ObservedObject var module: DropModule

    var body: some View {
        HStack(spacing: 6) {
            HeaderPill(text: module.moveMode ? "Move" : "Copy", icon: "arrow.left.arrow.right") {
                module.moveMode.toggle()
            }
            CircleIconButton(icon: "wifi", size: 20) {
                module.run(.airdrop, on: module.pendingFiles)
            }
            .help("AirDrop")
            CircleIconButton(icon: "doc.zipper", size: 20) {
                module.run(.zip, on: module.pendingFiles)
            }
            .help("Zip")
            CircleIconButton(icon: "photo.on.rectangle.angled", size: 20) {
                module.run(.convert(.png), on: module.pendingFiles)
            }
            .help("Convert to PNG")
            CircleIconButton(icon: "folder", size: 20) {
                module.run(module.moveMode ? .move : .copy, on: module.pendingFiles)
            }
            .help(module.moveMode ? "Move to folder…" : "Copy to folder…")
            CircleIconButton(icon: "trash", size: 20) {
                module.clearPending()
            }
            .help("Clear shelf")
        }
    }
}

/// Tile grid shown while a drag hovers; each tile is its own drop target.
struct DropGridView: View {
    @ObservedObject var module: DropModule

    var body: some View {
        VStack(spacing: 8) {
            row(DropGridAction.firstRow)
            if module.gridExpanded {
                row(DropGridAction.secondRow)
            }
        }
    }

    private func row(_ actions: [DropGridAction]) -> some View {
        HStack(spacing: 8) {
            ForEach(actions, id: \.self) { action in
                DropTile(action: action, module: module)
            }
        }
    }
}

struct DropTile: View {
    let action: DropGridAction
    @ObservedObject var module: DropModule
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: action.icon).font(.system(size: 15))
            Text(action.title).font(.system(size: 8))
        }
        .frame(width: 74, height: 50)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(targeted ? Theme.accent.opacity(0.5) : Theme.card)
        )
        .onDrop(of: [UTType.fileURL], isTargeted: Binding(
            get: { targeted },
            set: { hovering in
                targeted = hovering
                // Hovering the Expand tile reveals the second row without dropping.
                if hovering, action == .expand { module.gridExpanded = true }
            }
        )) { providers in
            guard action != .expand else { return false }
            module.handleGridDrop(action, providers: providers)
            return true
        }
    }
}

struct ShelfView: View {
    @ObservedObject var module: DropModule

    var body: some View {
        VStack(spacing: 6) {
            DropGridView(module: module)
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    Color.white.opacity(0.25),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.03)))
                .overlay(alignment: .topLeading) {
                    if module.pendingFiles.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "tray.and.arrow.down")
                                .font(.system(size: 22))
                                .foregroundStyle(.tertiary)
                            Text("Drop onto an action tile — or onto Shelf to stash")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(module.pendingFiles.prefix(8), id: \.self) { url in
                                VStack(spacing: 3) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                        .resizable()
                                        .frame(width: 34, height: 34)
                                    Text(url.lastPathComponent)
                                        .font(.system(size: 8))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .frame(width: 52)
                                }
                                .contextMenu {
                                    Button("Remove") {
                                        module.pendingFiles.removeAll { $0 == url }
                                    }
                                }
                            }
                        }
                        .padding(10)
                    }
                }
            if let status = module.statusMessage {
                Text(status)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
enum DropModuleShared {
    weak static var instance: DropModule?
}
