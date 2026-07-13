import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class DropModule: NotchModule, ObservableObject {
    static let moduleID = "drop"
    let id = DropModule.moduleID
    let name = "Drop Actions"
    let icon = "tray.and.arrow.down.fill"
    let hasPanel = true

    @Published var pendingFiles: [URL] = []
    @Published var statusMessage: String?
    private var statusTask: Task<Void, Never>?

    func activate() {}
    func deactivate() {
        pendingFiles = []
        statusMessage = nil
    }

    func panelView() -> AnyView { AnyView(DropGridView(module: self)) }

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
        case .airdrop:
            if let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) {
                service.perform(withItems: urls)
                clearPending()
            } else {
                showStatus("AirDrop unavailable")
            }
        case .zip:
            do {
                let archive = try DropActionRunner.zip(urls)
                showStatus("Zipped → \(archive.lastPathComponent)")
                clearPending()
            } catch { showStatus(error.localizedDescription) }
        case .convert(let format):
            do {
                for url in urls {
                    _ = try DropActionRunner.convert(url, to: format)
                }
                showStatus("Converted to \(format.rawValue.uppercased())")
                clearPending()
            } catch { showStatus(error.localizedDescription) }
        case .move, .copy:
            chooseFolder { [weak self] folder in
                guard let self, let folder else { return }
                do {
                    if case .move = action {
                        try DropActionRunner.move(urls, to: folder)
                        self.showStatus("Moved to \(folder.lastPathComponent)")
                    } else {
                        try DropActionRunner.copy(urls, to: folder)
                        self.showStatus("Copied to \(folder.lastPathComponent)")
                    }
                    self.clearPending()
                } catch { self.showStatus(error.localizedDescription) }
            }
        case .openWith:
            openWithMenu(urls: urls)
        }
    }

    func clearPending() { pendingFiles = [] }

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
    case airdrop
    case zip
    case convert(ImageFormat)
    case move
    case copy
    case openWith

    var title: String {
        switch self {
        case .airdrop: "AirDrop"
        case .zip: "Zip"
        case .convert(let f): f.rawValue.uppercased()
        case .move: "Move…"
        case .copy: "Copy…"
        case .openWith: "Open With"
        }
    }

    var icon: String {
        switch self {
        case .airdrop: "wifi"
        case .zip: "doc.zipper"
        case .convert: "photo.on.rectangle.angled"
        case .move: "folder"
        case .copy: "doc.on.doc"
        case .openWith: "arrow.up.forward.app"
        }
    }
}

struct DropGridView: View {
    @ObservedObject var module: DropModule

    private static let actions: [DropGridAction] = [
        .airdrop, .zip, .convert(.png), .convert(.jpeg), .move, .copy, .openWith,
    ]

    var body: some View {
        VStack(spacing: 10) {
            if !module.pendingFiles.isEmpty {
                HStack {
                    Image(systemName: "doc.fill")
                    Text("\(module.pendingFiles.count) file\(module.pendingFiles.count == 1 ? "" : "s") ready")
                        .font(.caption)
                    Button("Clear") { module.clearPending() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.secondary)
            } else if let status = module.statusMessage {
                Text(status).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Drop files on a tile — or anywhere to stage them")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(Self.actions, id: \.self) { action in
                    DropTile(action: action, module: module)
                }
            }
        }
    }
}

struct DropTile: View {
    let action: DropGridAction
    @ObservedObject var module: DropModule
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: action.icon).font(.system(size: 17))
            Text(action.title).font(.system(size: 10))
        }
        .frame(maxWidth: .infinity, minHeight: 58)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isTargeted ? Color.accentColor.opacity(0.4) : Color.white.opacity(0.08))
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { module.run(action, on: module.pendingFiles) }
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            let box = ProviderBox(providers: providers)
            Task { @MainActor in
                let urls = await FileDropLoader.urls(from: box)
                module.run(action, on: urls)
            }
            return true
        }
    }
}
