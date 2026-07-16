import Foundation
import IOKit

public struct BatterySlot: Equatable, Sendable {
    public init(label: String, percent: Int) { self.label = label; self.percent = percent }
    /// "L", "R", "Case", or "" for single-battery devices.
    public var label: String
    public var percent: Int
}

public struct BTDevice: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable {
        case airpods, headphones, mouse, keyboard, trackpad, controller, other

        var icon: String {
            switch self {
            case .airpods: "airpods"
            case .headphones: "headphones"
            case .mouse: "computermouse.fill"
            case .keyboard: "keyboard.fill"
            case .trackpad: "rectangle.fill"
            case .controller: "gamecontroller.fill"
            case .other: "wave.3.right"
            }
        }
    }

    public var id: String
    public var name: String
    public var kind: Kind
    public var batteries: [BatterySlot]

    public var minPercent: Int { batteries.map(\.percent).min() ?? 100 }
}

public enum BTBatteryScanner {
    /// Pure parse of an IORegistry property dictionary. Tested.
    public static func parse(properties: [String: Any]) -> BTDevice? {
        let name = (properties["DeviceName"] as? String)
            ?? (properties["Product"] as? String)
        guard let name, !name.isEmpty else { return nil }

        var slots: [BatterySlot] = []
        if let left = intValue(properties["BatteryPercentLeft"]) {
            slots.append(BatterySlot(label: "L", percent: left))
        }
        if let right = intValue(properties["BatteryPercentRight"]) {
            slots.append(BatterySlot(label: "R", percent: right))
        }
        if let box = intValue(properties["BatteryPercentCase"]) {
            slots.append(BatterySlot(label: "Case", percent: box))
        }
        if slots.isEmpty, let single = intValue(properties["BatteryPercent"]) {
            slots.append(BatterySlot(label: "", percent: single))
        }
        guard !slots.isEmpty else { return nil }

        let address = (properties["DeviceAddress"] as? String) ?? name
        return BTDevice(
            id: address,
            name: name,
            kind: inferKind(name: name, properties: properties),
            batteries: slots
        )
    }

    public static func inferKind(name: String, properties: [String: Any]) -> BTDevice.Kind {
        let haystack = "\(name) \(properties["Product"] as? String ?? "")".lowercased()
        if haystack.contains("airpods") { return .airpods }
        if haystack.contains("beats") || haystack.contains("headphone") { return .headphones }
        if haystack.contains("trackpad") { return .trackpad }
        if haystack.contains("mouse") { return .mouse }
        if haystack.contains("keyboard") { return .keyboard }
        if haystack.contains("controller") || haystack.contains("dualsense")
            || haystack.contains("dualshock") || haystack.contains("xbox") { return .controller }
        return .other
    }

    /// Kind inference from `system_profiler`'s device_minorType, falling back to the name.
    public static func kind(minorType: String, name: String) -> BTDevice.Kind {
        if name.lowercased().contains("airpods") { return .airpods }
        switch minorType.lowercased() {
        case "keyboard": return .keyboard
        case "mouse": return .mouse
        case "trackpad": return .trackpad
        case "headphones", "headset": return .headphones
        case "gamepad", "controller": return .controller
        default: return inferKind(name: name, properties: [:])
        }
    }

    /// Pure parse of `system_profiler -json SPBluetoothDataType` output. Tested.
    /// Only connected devices reporting a battery level are returned.
    public static func parseSystemProfiler(root: [String: Any]) -> [BTDevice] {
        guard let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var devices: [BTDevice] = []
        var seen = Set<String>()
        for section in sections {
            guard let connected = section["device_connected"] as? [[String: Any]] else { continue }
            for entry in connected {
                for (name, value) in entry {
                    guard let info = value as? [String: Any] else { continue }
                    var slots: [BatterySlot] = []
                    if let l = percentValue(info["device_batteryLevelLeft"]) {
                        slots.append(BatterySlot(label: "L", percent: l))
                    }
                    if let r = percentValue(info["device_batteryLevelRight"]) {
                        slots.append(BatterySlot(label: "R", percent: r))
                    }
                    if let box = percentValue(info["device_batteryLevelCase"]) {
                        slots.append(BatterySlot(label: "Case", percent: box))
                    }
                    if slots.isEmpty, let main = percentValue(info["device_batteryLevelMain"]) {
                        slots.append(BatterySlot(label: "", percent: main))
                    }
                    guard !slots.isEmpty else { continue }
                    let address = (info["device_addr"] as? String) ?? name
                    guard seen.insert(normalizedAddress(address)).inserted else { continue }
                    devices.append(BTDevice(
                        id: address,
                        name: name,
                        kind: kind(minorType: (info["device_minorType"] as? String) ?? "", name: name),
                        batteries: slots
                    ))
                }
            }
        }
        return devices
    }

    /// Runs `system_profiler` and parses connected Bluetooth device batteries.
    /// This is the reliable source: many Macs never populate the IORegistry HID
    /// battery keys, but the Bluetooth daemon reports them here.
    static func scanSystemProfiler() -> [BTDevice] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        proc.arguments = ["-json", "SPBluetoothDataType"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            return parseSystemProfiler(root: root)
        } catch {
            return []
        }
    }

    /// Union of the system_profiler source (authoritative) and the IORegistry
    /// scan, deduped by normalized address. Off the main thread — spawns a
    /// subprocess.
    static func scanAll() -> [BTDevice] {
        var result = scanSystemProfiler()
        var seen = Set(result.map { normalizedAddress($0.id) })
        for device in scan() where seen.insert(normalizedAddress(device.id)).inserted {
            result.append(device)
        }
        return result.sorted { $0.name < $1.name }
    }

    /// Walks the IORegistry for Bluetooth HID devices reporting battery levels.
    static func scan() -> [BTDevice] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AppleDeviceManagementHIDEventService"),
            &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var devices: [BTDevice] = []
        var seen = Set<String>()
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            defer { IOObjectRelease(entry) }

            var propsRef: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = propsRef?.takeRetainedValue() as? [String: Any],
                  let device = parse(properties: props),
                  seen.insert(device.id).inserted else { continue }
            devices.append(device)
        }
        return devices.sorted { $0.name < $1.name }
    }

    private static func intValue(_ any: Any?) -> Int? {
        guard let number = any as? NSNumber else { return nil }
        let value = number.intValue
        return (0...100).contains(value) ? value : nil
    }

    /// Accepts NSNumber or "NN%"/"NN" strings (system_profiler reports strings).
    public static func percentValue(_ any: Any?) -> Int? {
        if let number = any as? NSNumber { return (0...100).contains(number.intValue) ? number.intValue : nil }
        if let string = any as? String {
            let trimmed = string.replacingOccurrences(of: "%", with: "")
                .trimmingCharacters(in: .whitespaces)
            if let value = Int(trimmed), (0...100).contains(value) { return value }
        }
        return nil
    }

    /// Lowercased, separator-free address for cross-source dedup (IORegistry and
    /// system_profiler format addresses differently).
    static func normalizedAddress(_ address: String) -> String {
        address.lowercased()
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
    }
}
