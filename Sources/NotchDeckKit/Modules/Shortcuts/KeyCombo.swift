import Foundation

/// A recorded global shortcut. Modifiers use Carbon flag values so they can
/// feed RegisterEventHotKey directly.
public struct KeyCombo: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var carbonModifiers: UInt32

    public init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    // Carbon: cmdKey 256, shiftKey 512, optionKey 2048, controlKey 4096.
    public static func carbonModifiers(fromCocoa raw: UInt) -> UInt32 {
        var flags: UInt32 = 0
        if raw & (1 << 20) != 0 { flags |= 256 }
        if raw & (1 << 17) != 0 { flags |= 512 }
        if raw & (1 << 19) != 0 { flags |= 2048 }
        if raw & (1 << 18) != 0 { flags |= 4096 }
        return flags
    }

    public var display: String {
        var out = ""
        if carbonModifiers & 4096 != 0 { out += "⌃" }
        if carbonModifiers & 2048 != 0 { out += "⌥" }
        if carbonModifiers & 512 != 0 { out += "⇧" }
        if carbonModifiers & 256 != 0 { out += "⌘" }
        return out + Self.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        let names: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
            31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K",
            45: "N", 46: "M", 49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 53: "⎋",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        ]
        return names[code] ?? "key\(code)"
    }
}
