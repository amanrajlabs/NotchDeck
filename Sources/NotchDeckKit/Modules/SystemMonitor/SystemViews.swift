import SwiftUI

@MainActor
final class SystemMonitorModule: NotchModule, ObservableObject {
    static let moduleID = "system"
    let id = SystemMonitorModule.moduleID
    let name = "System Monitor"
    let icon = "gauge.with.dots.needle.50percent"
    let hasPanel = true

    @Published private(set) var cpuUsage: Double = 0
    @Published private(set) var memory: (used: Double, total: Double) = (0, 1)
    @Published private(set) var storage: (free: Double, total: Double) = (0, 1)

    private var timer: Timer?
    private var lastSample: CPUSample?

    func activate() {}
    func deactivate() { stopSampling() }

    func panelView() -> AnyView { AnyView(SystemPanelView(module: self)) }

    /// Sampling runs only while the panel is on screen.
    func startSampling() {
        guard timer == nil else { return }
        sampleOnce()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { SystemMonitorShared.instance?.sampleOnce() }
        }
        SystemMonitorShared.instance = self
    }

    func stopSampling() {
        timer?.invalidate()
        timer = nil
        lastSample = nil
    }

    private func sampleOnce() {
        if let current = SystemStatsSampler.cpuSample() {
            if let previous = lastSample {
                cpuUsage = SystemStatsMath.cpuUsage(previous: previous, current: current)
            }
            lastSample = current
        }
        if let mem = SystemStatsSampler.memory() {
            memory = (Double(mem.usedBytes), Double(mem.totalBytes))
        }
        if let disk = SystemStatsSampler.storage() {
            storage = (Double(disk.freeBytes), Double(disk.totalBytes))
        }
    }
}

@MainActor
enum SystemMonitorShared {
    weak static var instance: SystemMonitorModule?
}

struct SystemPanelView: View {
    @ObservedObject var module: SystemMonitorModule

    var body: some View {
        HStack(spacing: 24) {
            GaugeTile(
                title: "CPU",
                fraction: module.cpuUsage,
                caption: "\(Int((module.cpuUsage * 100).rounded()))%"
            )
            GaugeTile(
                title: "Memory",
                fraction: module.memory.used / max(module.memory.total, 1),
                caption: Self.gigabytes(module.memory.used) + " / " + Self.gigabytes(module.memory.total)
            )
            GaugeTile(
                title: "Storage",
                fraction: 1 - module.storage.free / max(module.storage.total, 1),
                caption: Self.gigabytes(module.storage.free) + " free"
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { module.startSampling() }
        .onDisappear { module.stopSampling() }
    }

    static func gigabytes(_ bytes: Double) -> String {
        String(format: "%.0f GB", bytes / 1_073_741_824)
    }
}

struct GaugeTile: View {
    let title: String
    let fraction: Double
    let caption: String

    private var color: Color {
        if fraction > 0.85 { return .red }
        if fraction > 0.65 { return .orange }
        return .green
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: max(0.01, min(fraction, 1)))
                    .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .frame(width: 66, height: 66)
            .animation(.snappy(duration: 0.4), value: fraction)
            Text(caption)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
