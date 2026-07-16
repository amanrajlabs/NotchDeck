import SwiftUI
import UserNotifications

@MainActor
final class BluetoothModule: NotchModule, ObservableObject {
    static let moduleID = "bluetooth"
    let id = BluetoothModule.moduleID
    let name = "Bluetooth Battery"
    let icon = "airpods"
    let hasPanel = true
    var preferredHeight: CGFloat { 168 }

    @Published private(set) var devices: [BTDevice] = []
    private var refreshTimer: Timer?
    private var notifiedDeviceIDs = Set<String>()
    private static let lowBatteryThreshold = 20

    func activate() {
        refresh()
        // Scan spawns a subprocess (system_profiler); once a minute while the
        // module is active keeps live data fresh without a tight cadence.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { BluetoothModuleShared.instance?.refresh() }
        }
        BluetoothModuleShared.instance = self
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        }
    }

    func deactivate() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        devices = []
    }

    func refresh() {
        // scanAll spawns system_profiler (~1s) — keep it off the main thread.
        Task.detached(priority: .utility) { [weak self] in
            let scanned = BTBatteryScanner.scanAll()
            await MainActor.run { self?.applyScan(scanned) }
        }
    }

    private func applyScan(_ scanned: [BTDevice]) {
        if devices != scanned { devices = scanned }
        notifyLowBatteries(scanned)
    }

    func panelView() -> AnyView { AnyView(BTPanelView(module: self)) }

    func headerBadge() -> AnyView? {
        AnyView(
            Text("\(devices.count) device\(devices.count == 1 ? "" : "s")")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        )
    }

    func liveActivityView() -> AnyView? {
        guard let low = devices.first(where: { $0.minPercent <= Self.lowBatteryThreshold }) else {
            return nil
        }
        return AnyView(BTLowBatteryPill(device: low))
    }

    private func notifyLowBatteries(_ devices: [BTDevice]) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        for device in devices where device.minPercent <= Self.lowBatteryThreshold {
            guard notifiedDeviceIDs.insert(device.id).inserted else { continue }
            let content = UNMutableNotificationContent()
            content.title = "\(device.name) battery low"
            content.body = "\(device.minPercent)% remaining"
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "bt-low-\(device.id)", content: content, trigger: nil)
            )
        }
        // Allow re-notification after a device recovers (recharged).
        for id in notifiedDeviceIDs {
            if let device = devices.first(where: { $0.id == id }), device.minPercent > 50 {
                notifiedDeviceIDs.remove(id)
            }
        }
    }
}

@MainActor
enum BluetoothModuleShared {
    weak static var instance: BluetoothModule?
}

struct BTLowBatteryPill: View {
    let device: BTDevice

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: device.kind.icon)
                .font(.system(size: 11))
            Text("\(device.minPercent)%")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.red)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

struct BTPanelView: View {
    @ObservedObject var module: BluetoothModule

    var body: some View {
        Group {
            if module.devices.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "airpods")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("No Bluetooth devices with battery info")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(module.devices) { device in
                            HStack(spacing: 12) {
                                Image(systemName: device.kind.icon)
                                    .font(.system(size: 16))
                                    .frame(width: 24)
                                Text(device.name)
                                    .font(.system(size: 13))
                                    .lineLimit(1)
                                Spacer()
                                ForEach(device.batteries, id: \.label) { slot in
                                    BatteryRing(slot: slot)
                                }
                            }
                            .padding(.horizontal, 4)
                        }
                    }
                }
            }
        }
        .onAppear { module.refresh() }
    }
}

struct BatteryRing: View {
    let slot: BatterySlot

    private var color: Color {
        if slot.percent <= 20 { return .red }
        if slot.percent <= 40 { return .orange }
        return .green
    }

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: Double(slot.percent) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(slot.percent)")
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
            }
            .frame(width: 30, height: 30)
            if !slot.label.isEmpty {
                Text(slot.label)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
