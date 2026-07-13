import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class DashboardModule: NotchModule, ObservableObject {
    static let moduleID = "dashboard"
    let id = DashboardModule.moduleID
    let name = "Dashboard"
    let icon = "square.grid.2x2.fill"
    let hasPanel = true

    let weather = WeatherService()
    let toggles = QuickToggleEngine()

    @Published var launcherPaths: [String] {
        didSet { UserDefaults.standard.set(launcherPaths, forKey: "dashboard.launchers") }
    }
    @Published var activeProfile: String {
        didSet { UserDefaults.standard.set(activeProfile, forKey: "dashboard.profile") }
    }

    static let profiles = ["Default", "Work", "Focus"]
    weak var registry: ModuleRegistry?

    init() {
        launcherPaths = UserDefaults.standard.stringArray(forKey: "dashboard.launchers") ?? []
        activeProfile = UserDefaults.standard.string(forKey: "dashboard.profile") ?? "Default"
    }

    func activate() {
        weather.activate()
        toggles.activate()
    }

    func deactivate() {
        weather.deactivate()
        toggles.deactivate()
    }

    func panelView() -> AnyView { AnyView(DashboardPanelView(module: self)) }

    // MARK: Profiles — each stores its own enabled-module set.

    func switchProfile(to profile: String) {
        guard let registry else {
            activeProfile = profile
            return
        }
        // Save current module set under the outgoing profile.
        UserDefaults.standard.set(
            Array(registry.enabledIDs), forKey: "profile.\(activeProfile).modules"
        )
        activeProfile = profile
        guard let saved = UserDefaults.standard.stringArray(forKey: "profile.\(profile).modules")
        else { return } // first use of a profile keeps the current set
        let wanted = Set(saved + [Self.moduleID]) // never disable the dashboard itself
        for module in registry.modules {
            registry.setEnabled(module.id, wanted.contains(module.id))
        }
    }

    // MARK: Launchers

    func addLauncher() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url, let self else { return }
                if !self.launcherPaths.contains(url.path) {
                    self.launcherPaths.append(url.path)
                }
            }
        }
    }

    func removeLauncher(_ path: String) {
        launcherPaths.removeAll { $0 == path }
    }

    func launch(_ path: String) {
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: path),
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}

// MARK: - Views

struct DashboardPanelView: View {
    @ObservedObject var module: DashboardModule
    @ObservedObject private var weather: WeatherService
    @ObservedObject private var toggles: QuickToggleEngine

    init(module: DashboardModule) {
        self.module = module
        self.weather = module.weather
        self.toggles = module.toggles
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                WeatherTile(weather: weather)
                togglesGrid
                Spacer(minLength: 0)
                profilePicker
            }
            launcherRow
        }
    }

    private var togglesGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(92), spacing: 6), count: 3),
            spacing: 6
        ) {
            ToggleTile(title: "Dark Mode", icon: "moon.fill", isOn: toggles.darkMode) {
                toggles.toggleDarkMode()
            }
            ToggleTile(title: "Keep Awake", icon: "cup.and.saucer.fill", isOn: toggles.keepAwake) {
                toggles.toggleKeepAwake()
            }
            ToggleTile(
                title: "Desktop", icon: "menubar.dock.rectangle",
                isOn: toggles.desktopIconsHidden
            ) {
                toggles.toggleDesktopIcons()
            }
            if toggles.nightShiftAvailable {
                ToggleTile(title: "Night Shift", icon: "moon.stars.fill", isOn: toggles.nightShift) {
                    toggles.toggleNightShift()
                }
            }
            if toggles.trueToneAvailable {
                ToggleTile(title: "True Tone", icon: "display", isOn: toggles.trueTone) {
                    toggles.toggleTrueTone()
                }
            }
        }
    }

    private var profilePicker: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text("Profile").font(.system(size: 10)).foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { module.activeProfile },
                set: { module.switchProfile(to: $0) }
            )) {
                ForEach(DashboardModule.profiles, id: \.self) { Text($0) }
            }
            .pickerStyle(.menu)
            .frame(width: 100)
        }
    }

    private var launcherRow: some View {
        HStack(spacing: 10) {
            ForEach(module.launcherPaths, id: \.self) { path in
                Button { module.launch(path) } label: {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                        .resizable()
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .help(FileManager.default.displayName(atPath: path))
                .contextMenu {
                    Button("Remove") { module.removeLauncher(path) }
                }
            }
            Button { module.addLauncher() } label: {
                Image(systemName: "plus.circle.dashed")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .help("Add app launcher")
            Spacer()
        }
    }
}

struct WeatherTile: View {
    @ObservedObject var weather: WeatherService

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let snapshot = weather.snapshot {
                HStack(spacing: 6) {
                    Image(systemName: WeatherParser.symbol(for: snapshot.code))
                        .font(.system(size: 18))
                        .symbolRenderingMode(.multicolor)
                    Text("\(Int(snapshot.tempC.rounded()))°")
                        .font(.system(size: 22, weight: .semibold))
                }
                Text("H \(Int(snapshot.hiC.rounded()))°  L \(Int(snapshot.loC.rounded()))°")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                if let city = weather.locationName {
                    Text(city).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            } else {
                Image(systemName: "cloud.fill").foregroundStyle(.secondary)
                Text("Weather…").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(width: 120, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
    }
}

struct ToggleTile: View {
    let title: String
    let icon: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11))
                Text(title).font(.system(size: 10, weight: .medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isOn ? Color.accentColor.opacity(0.55) : Color.white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }
}
