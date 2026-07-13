import SwiftUI

@MainActor
final class NotesModule: NotchModule, ObservableObject {
    static let moduleID = "notes"
    let id = NotesModule.moduleID
    let name = "Notes"
    let icon = "note.text"
    let hasPanel = true

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

    var body: some View {
        TextEditor(text: $module.text)
            .font(.system(size: 12))
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
            .overlay(alignment: .topLeading) {
                if module.text.isEmpty {
                    Text("Quick notes — saved automatically")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 12)
                        .padding(.leading, 12)
                        .allowsHitTesting(false)
                }
            }
    }
}
