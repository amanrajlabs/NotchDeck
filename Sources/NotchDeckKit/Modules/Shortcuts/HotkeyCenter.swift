import AppKit
import Carbon.HIToolbox

/// Registers app-global hotkeys via Carbon (no Accessibility permission
/// needed, and the combos are consumed rather than observed).
@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    private var refs: [String: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var idsByName: [String: UInt32] = [:]
    private var nextID: UInt32 = 1
    private var handlerInstalled = false

    func bind(_ name: String, to combo: KeyCombo?, action: @escaping () -> Void) {
        if let existing = refs.removeValue(forKey: name) {
            UnregisterEventHotKey(existing)
            if let id = idsByName.removeValue(forKey: name) { actions[id] = nil }
        }
        guard let combo else { return }
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4E44_484B) /* 'NDHK' */, id: id)
        let status = RegisterEventHotKey(
            combo.keyCode, combo.carbonModifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &hotKeyRef
        )
        guard status == noErr, let hotKeyRef else { return }
        refs[name] = hotKeyRef
        idsByName[name] = id
        actions[id] = action
    }

    fileprivate func fire(_ id: UInt32) { actions[id]?() }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            let id = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotkeyCenter.shared.fire(id) }
            }
            return noErr
        }, 1, &eventType, nil, nil)
    }
}
