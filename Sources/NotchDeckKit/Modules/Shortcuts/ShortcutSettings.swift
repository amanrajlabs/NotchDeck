import SwiftUI

@MainActor
final class ShortcutSettings: ObservableObject {
    static let shared = ShortcutSettings()

    @Published var toggleNotch: KeyCombo? { didSet { save("hotkey.toggle", toggleNotch) } }
    @Published var nextModule: KeyCombo? { didSet { save("hotkey.next", nextModule) } }
    @Published var prevModule: KeyCombo? { didSet { save("hotkey.prev", prevModule) } }
    @Published var snooze: KeyCombo? { didSet { save("hotkey.snooze", snooze) } }
    @Published var snoozeMinutes: Int {
        didSet { UserDefaults.standard.set(snoozeMinutes, forKey: "hotkey.snoozeMinutes") }
    }

    init() {
        toggleNotch = Self.load("hotkey.toggle")
        nextModule = Self.load("hotkey.next")
        prevModule = Self.load("hotkey.prev")
        snooze = Self.load("hotkey.snooze")
        let stored = UserDefaults.standard.integer(forKey: "hotkey.snoozeMinutes")
        snoozeMinutes = stored == 0 ? 15 : stored
    }

    func rebindAll(shell: NotchShellController) {
        HotkeyCenter.shared.bind("toggle", to: toggleNotch) { [weak shell] in
            shell?.toggleFirstPanel()
        }
        HotkeyCenter.shared.bind("next", to: nextModule) { [weak shell] in
            shell?.cycleModule(by: 1)
        }
        HotkeyCenter.shared.bind("prev", to: prevModule) { [weak shell] in
            shell?.cycleModule(by: -1)
        }
        HotkeyCenter.shared.bind("snooze", to: snooze) { [weak shell] in
            guard let shell else { return }
            shell.isSnoozed ? shell.wake() : shell.snooze(minutes: ShortcutSettings.shared.snoozeMinutes)
        }
    }

    private func save(_ key: String, _ combo: KeyCombo?) {
        if let combo, let data = try? JSONEncoder().encode(combo) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static func load(_ key: String) -> KeyCombo? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(KeyCombo.self, from: data)
    }
}

/// Click, press a combo, done. Esc cancels; ⌫ clears.
struct ShortcutRecorderField: View {
    let title: String
    @Binding var combo: KeyCombo?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button(recording ? "Press keys…" : (combo?.display ?? "Record")) {
                recording ? stop() : start()
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            defer { stop() }
            if event.keyCode == 53 { return nil } // Esc = cancel
            if event.keyCode == 51 { combo = nil; return nil } // Delete = clear
            let mods = KeyCombo.carbonModifiers(fromCocoa: event.modifierFlags.rawValue)
            guard mods != 0 else { return nil } // require at least one modifier
            combo = KeyCombo(keyCode: UInt32(event.keyCode), carbonModifiers: mods)
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}
