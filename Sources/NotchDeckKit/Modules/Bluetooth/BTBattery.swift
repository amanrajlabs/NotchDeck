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
}
