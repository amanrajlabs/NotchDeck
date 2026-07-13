import AppKit
import Combine
import IOKit.pwr_mgt

/// System quick-toggles. Private-framework toggles (Night Shift, True Tone)
/// are best-effort and hidden when unavailable.
@MainActor
final class QuickToggleEngine: ObservableObject {
    @Published private(set) var darkMode = false
    @Published private(set) var keepAwake = false
    @Published private(set) var nightShift = false
    @Published private(set) var trueTone = false
    @Published private(set) var desktopIconsHidden = false

    private var assertionID: IOPMAssertionID = 0
    private var appearanceObserver: NSObjectProtocol?
    private let blueLight = CoreBrightnessClient(className: "CBBlueLightClient")
    private let trueToneClient = CoreBrightnessClient(className: "CBTrueToneClient")

    var nightShiftAvailable: Bool { blueLight.isAvailable }
    var trueToneAvailable: Bool { trueToneClient.isAvailable }

    func activate() {
        syncDarkMode()
        desktopIconsHidden = !Self.finderCreatesDesktop()
        nightShift = blueLight.readEnabled() ?? false
        trueTone = trueToneClient.readEnabled() ?? false
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in QuickToggleEngineShared.instance?.syncDarkMode() }
        }
        QuickToggleEngineShared.instance = self
    }

    func deactivate() {
        if let appearanceObserver {
            DistributedNotificationCenter.default().removeObserver(appearanceObserver)
        }
        appearanceObserver = nil
        releaseAwakeAssertion()
    }

    // MARK: Dark mode

    private func syncDarkMode() {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        darkMode = (global?["AppleInterfaceStyle"] as? String) == "Dark"
    }

    func toggleDarkMode() {
        let script = NSAppleScript(source: """
        tell application "System Events" to tell appearance preferences to set dark mode to not dark mode
        """)
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if error == nil { darkMode.toggle() }
    }

    // MARK: Keep awake

    func toggleKeepAwake() {
        if keepAwake {
            releaseAwakeAssertion()
        } else {
            var id: IOPMAssertionID = 0
            let ok = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "NotchDeck Keep Awake" as CFString,
                &id
            )
            if ok == kIOReturnSuccess {
                assertionID = id
                keepAwake = true
            }
        }
    }

    private func releaseAwakeAssertion() {
        if keepAwake, assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        keepAwake = false
    }

    // MARK: Night Shift / True Tone (private CoreBrightness)

    func toggleNightShift() {
        if blueLight.setEnabled(!nightShift) { nightShift.toggle() }
    }

    func toggleTrueTone() {
        if trueToneClient.setEnabled(!trueTone) { trueTone.toggle() }
    }

    // MARK: Desktop icons

    func toggleDesktopIcons() {
        let newCreates = desktopIconsHidden // hidden → re-create
        CFPreferencesSetAppValue(
            "CreateDesktop" as CFString,
            newCreates ? kCFBooleanTrue : kCFBooleanFalse,
            "com.apple.finder" as CFString
        )
        CFPreferencesAppSynchronize("com.apple.finder" as CFString)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Finder"]
        try? process.run()
        desktopIconsHidden = !newCreates
    }

    private static func finderCreatesDesktop() -> Bool {
        guard let value = CFPreferencesCopyAppValue(
            "CreateDesktop" as CFString, "com.apple.finder" as CFString
        ) else { return true }
        return (value as? Bool) ?? true
    }
}

@MainActor
enum QuickToggleEngineShared {
    weak static var instance: QuickToggleEngine?
}

/// Thin ObjC-runtime wrapper for CBBlueLightClient / CBTrueToneClient.
final class CoreBrightnessClient {
    private let instance: NSObject?

    init(className: String) {
        _ = dlopen(
            "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
            RTLD_LAZY
        )
        instance = (NSClassFromString(className) as? NSObject.Type)?.init()
    }

    var isAvailable: Bool { instance != nil }

    /// Reads `-enabled` when the class exposes it (True Tone does; Night
    /// Shift's status struct is not worth the fragility — returns nil).
    func readEnabled() -> Bool? {
        guard let instance else { return nil }
        let selector = NSSelectorFromString("enabled")
        guard instance.responds(to: selector),
              let method = instance.method(for: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(method, to: Getter.self)(instance, selector)
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        guard let instance else { return false }
        let selector = NSSelectorFromString("setEnabled:")
        guard instance.responds(to: selector),
              let method = instance.method(for: selector) else { return false }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Bool
        return unsafeBitCast(method, to: Setter.self)(instance, selector, enabled)
    }
}
