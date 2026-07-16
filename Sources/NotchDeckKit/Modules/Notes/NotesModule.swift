import SwiftUI

@MainActor
final class NotesModule: NotchModule, ObservableObject {
    static let moduleID = "notes"
    let id = NotesModule.moduleID
    let name = "Notes"
    let icon = "note.text"
    let hasPanel = true
    var preferredHeight: CGFloat { 176 }

    @Published var notes: [URL] = []
    @Published var selected: URL?
    @Published var text: String = "" {
        didSet { if !isLoading { scheduleSave() } }
    }

    private var isLoading = false
    private var saveTask: Task<Void, Never>?

    private static var notesDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchDeck/Notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func activate() {
        migrateLegacyNote()
        reloadList()
        if selected == nil { selected = notes.first }
        load(selected)
    }

    func deactivate() {
        saveNow()
    }

    func panelView() -> AnyView { AnyView(NotesPanelView(module: self)) }

    func headerBadge() -> AnyView? {
        let words = text.split(whereSeparator: \.isWhitespace).count
        let noteTitle = selected.map { self.title(of: $0) } ?? "Notes"
        return AnyView(
            Text("\(noteTitle) · \(words) words")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        )
    }

    /// Appends a markdown snippet at the end of the note.
    func insert(_ snippet: String) {
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += snippet
    }

    // MARK: Multi-note management

    private func migrateLegacyNote() {
        let legacy = Self.notesDir.deletingLastPathComponent().appendingPathComponent("notes.txt")
        let target = Self.notesDir.appendingPathComponent("Scratchpad.md")
        if FileManager.default.fileExists(atPath: legacy.path),
           !FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.moveItem(at: legacy, to: target)
        }
    }

    private func reloadList() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: Self.notesDir, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        notes = urls.filter { $0.pathExtension == "md" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
    }

    func createNote() {
        saveNow()
        let url = DropActionRunner.uniqueURL(in: Self.notesDir, base: "Note", ext: "md")
        try? "".write(to: url, atomically: true, encoding: .utf8)
        reloadList()
        select(url)
    }

    func deleteNote(_ url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        reloadList()
        if selected == url {
            selected = notes.first
            load(selected)
        }
    }

    func select(_ url: URL) {
        guard url != selected else { return }
        saveNow()
        selected = url
        load(url)
    }

    func title(of url: URL) -> String {
        let head = (try? String(contentsOf: url, encoding: .utf8))?
            .split(separator: "\n").first.map(String.init)
        return (head?.isEmpty == false ? head! : url.deletingPathExtension().lastPathComponent)
    }

    private func load(_ url: URL?) {
        isLoading = true
        text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        isLoading = false
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        guard let selected else { return }
        try? text.write(to: selected, atomically: true, encoding: .utf8)
    }
}

struct NotesPanelView: View {
    @ObservedObject var module: NotesModule

    private static let tools: [(label: String, icon: String, snippet: String)] = [
        ("Bold", "bold", "**bold**"),
        ("Italic", "italic", "*italic*"),
        ("Strike", "strikethrough", "~~strike~~"),
        ("Code", "chevron.left.forwardslash.chevron.right", "`code`"),
        ("List", "list.bullet", "- item"),
        ("Number", "list.number", "1. item"),
        ("Heading", "textformat.size", "# Heading"),
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            sidebar.frame(width: 120, alignment: .leading)
            toolbar.frame(width: 132)
            TextEditor(text: $module.text)
                .font(.system(size: 11, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
                .overlay(alignment: .topLeading) {
                    if module.text.isEmpty {
                        Text("Quick notes — saved automatically, markdown friendly")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .padding(12)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { module.createNote() } label: {
                Label("New note", systemImage: "plus").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            ForEach(module.notes, id: \.self) { url in
                Text(module.title(of: url))
                    .font(.system(size: 10, weight: url == module.selected ? .bold : .regular))
                    .lineLimit(1)
                    .onTapGesture { module.select(url) }
                    .contextMenu { Button("Delete") { module.deleteNote(url) } }
            }
            Spacer()
        }
    }

    private var toolbar: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 5), GridItem(.flexible())], spacing: 5) {
            ForEach(Self.tools, id: \.label) { tool in
                Button {
                    module.insert(tool.snippet)
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tool.icon).font(.system(size: 11))
                        Text(tool.label).font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
