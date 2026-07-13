import SwiftUI

@MainActor
final class NotesModule: NotchModule, ObservableObject {
    static let moduleID = "notes"
    let id = NotesModule.moduleID
    let name = "Notes"
    let icon = "note.text"
    let hasPanel = true
    var preferredHeight: CGFloat { 176 }

    @Published var text: String = "" {
        didSet { scheduleSave() }
    }

    private var saveTask: Task<Void, Never>?

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchDeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("notes.txt")
    }

    func activate() {
        text = (try? String(contentsOf: Self.fileURL, encoding: .utf8)) ?? ""
    }

    func deactivate() {
        saveNow()
    }

    func panelView() -> AnyView { AnyView(NotesPanelView(module: self)) }

    func headerBadge() -> AnyView? {
        let words = text.split(whereSeparator: \.isWhitespace).count
        return AnyView(
            Text("\(words) words")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        )
    }

    /// Appends a markdown snippet at the end of the note.
    func insert(_ snippet: String) {
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += snippet
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
        try? text.write(to: Self.fileURL, atomically: true, encoding: .utf8)
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
        HStack(alignment: .top, spacing: 14) {
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
