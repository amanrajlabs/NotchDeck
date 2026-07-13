import AppKit
import CoreAudio
import Combine

struct HUDEvent: Equatable {
    enum Kind { case volume, brightness }
    var kind: Kind
    var level: Double // 0...1
    var muted: Bool
}

@MainActor
final class HUDController: ObservableObject {
    @Published private(set) var event: HUDEvent?

    private let settings: SettingsStore
    private var hideTask: Task<Void, Never>?
    private var volumeWatcher: VolumeWatcher?
    private var brightnessTimer: Timer?
    private let brightnessReader = BrightnessReader()
    private var lastBrightness: Float = -1
    private var lastBezelKill = Date.distantPast

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func activate() {
        volumeWatcher = VolumeWatcher { [weak self] level, muted in
            self?.post(HUDEvent(kind: .volume, level: level, muted: muted))
        }
        if brightnessReader.isAvailable {
            lastBrightness = brightnessReader.read() ?? -1
            // Reading one float twice a second is negligible; only runs while
            // the module is enabled.
            brightnessTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                MainActor.assumeIsolated { HUDControllerShared.instance?.pollBrightness() }
            }
            HUDControllerShared.instance = self
        }
    }

    func deactivate() {
        volumeWatcher = nil
        brightnessTimer?.invalidate()
        brightnessTimer = nil
        hideTask?.cancel()
        event = nil
    }

    private func pollBrightness() {
        guard let value = brightnessReader.read() else { return }
        defer { lastBrightness = value }
        guard lastBrightness >= 0, abs(value - lastBrightness) > 0.001 else { return }
        post(HUDEvent(kind: .brightness, level: Double(value), muted: false))
    }

    private func post(_ newEvent: HUDEvent) {
        event = newEvent
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1400))
            guard !Task.isCancelled else { return }
            self?.event = nil
        }
        suppressSystemBezelIfEnabled()
    }

    /// Experimental: keeps Apple's bezel from appearing by killing OSDUIHelper
    /// (launchd restarts it on demand). Best effort, throttled.
    private func suppressSystemBezelIfEnabled() {
        guard settings.hudSuppressSystemBezel,
              Date().timeIntervalSince(lastBezelKill) > 2 else { return }
        lastBezelKill = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["OSDUIHelper"]
        try? process.run()
    }
}

@MainActor
enum HUDControllerShared {
    weak static var instance: HUDController?
}

// MARK: - CoreAudio volume watcher

/// Listens for output-volume and mute changes on the default output device,
/// re-attaching when the default device changes.
final class VolumeWatcher: @unchecked Sendable {
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private let onChange: @MainActor (Double, Bool) -> Void

    /// 'vmvc' — kAudioHardwareServiceDeviceProperty_VirtualMainVolume; the
    /// named constant lives in a header SPM doesn't see.
    private static let virtualMainVolumeSelector = AudioObjectPropertySelector(0x766D_7663)

    private let volumeAddress = AudioObjectPropertyAddress(
        mSelector: VolumeWatcher.virtualMainVolumeSelector,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private let muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private let defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private lazy var deviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.emit()
    }
    private lazy var defaultChangedListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.detachFromDevice()
        self?.attachToDefaultDevice()
    }

    init(onChange: @escaping @MainActor (Double, Bool) -> Void) {
        self.onChange = onChange
        var address = defaultDeviceAddress
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, defaultChangedListener
        )
        attachToDefaultDevice()
    }

    deinit {
        var address = defaultDeviceAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, defaultChangedListener
        )
        detachFromDevice()
    }

    private func attachToDefaultDevice() {
        var address = defaultDeviceAddress
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        ) == noErr, id != kAudioObjectUnknown else { return }
        deviceID = id

        var volAddr = volumeAddress
        var muteAddr = muteAddress
        if AudioObjectHasProperty(deviceID, &volAddr) {
            AudioObjectAddPropertyListenerBlock(deviceID, &volAddr, .main, deviceListener)
        }
        if AudioObjectHasProperty(deviceID, &muteAddr) {
            AudioObjectAddPropertyListenerBlock(deviceID, &muteAddr, .main, deviceListener)
        }
    }

    private func detachFromDevice() {
        guard deviceID != kAudioObjectUnknown else { return }
        var volAddr = volumeAddress
        var muteAddr = muteAddress
        AudioObjectRemovePropertyListenerBlock(deviceID, &volAddr, .main, deviceListener)
        AudioObjectRemovePropertyListenerBlock(deviceID, &muteAddr, .main, deviceListener)
        deviceID = AudioObjectID(kAudioObjectUnknown)
    }

    /// Called on the main queue by the listener blocks.
    private func emit() {
        guard deviceID != kAudioObjectUnknown else { return }
        var volAddr = volumeAddress
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(deviceID, &volAddr, 0, nil, &size, &volume) == noErr else { return }

        var muted: UInt32 = 0
        var muteAddr = muteAddress
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(deviceID, &muteAddr) {
            AudioObjectGetPropertyData(deviceID, &muteAddr, 0, nil, &muteSize, &muted)
        }

        let level = Double(volume)
        let isMuted = muted == 1
        DispatchQueue.main.async { [onChange] in
            MainActor.assumeIsolated { onChange(level, isMuted) }
        }
    }
}

// MARK: - Brightness (private DisplayServices, best effort)

final class BrightnessReader: @unchecked Sendable {
    private typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private let getBrightness: GetBrightness?

    init() {
        if let handle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_LAZY
        ), let symbol = dlsym(handle, "DisplayServicesGetBrightness") {
            getBrightness = unsafeBitCast(symbol, to: GetBrightness.self)
        } else {
            getBrightness = nil
        }
    }

    var isAvailable: Bool { getBrightness != nil }

    func read() -> Float? {
        guard let getBrightness else { return nil }
        var value: Float = 0
        return getBrightness(CGMainDisplayID(), &value) == 0 ? value : nil
    }
}
