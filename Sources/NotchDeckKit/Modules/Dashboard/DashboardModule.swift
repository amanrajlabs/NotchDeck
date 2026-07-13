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
    let screenTime = AppUsageTracker()

    var preferredHeight: CGFloat { 208 }

    @Published var launcherPaths: [String] {
        didSet { UserDefaults.standard.set(launcherPaths, forKey: "dashboard.launchers") }
    }
    @Published var activeProfile: String {
        didSet { UserDefaults.standard.set(activeProfile, forKey: "dashboard.profile") }
    }

    static let profiles = ["Default", "Work", "Focus"]
    weak var registry: ModuleRegistry?
    weak var calendarSource: CalendarSource?
    weak var pomodoro: PomodoroModule?

    init() {
        launcherPaths = UserDefaults.standard.stringArray(forKey: "dashboard.launchers") ?? []
        activeProfile = UserDefaults.standard.string(forKey: "dashboard.profile") ?? "Default"
    }

    func activate() {
        weather.activate()
        toggles.activate()
        screenTime.activate()
    }

    func deactivate() {
        weather.deactivate()
        toggles.deactivate()
        screenTime.deactivate()
    }

    func panelView() -> AnyView { AnyView(DashboardPanelView(module: self)) }

    func headerBadge() -> AnyView? {
        AnyView(HeaderPill(text: activeProfile, icon: "person.crop.circle") { [weak self] in
            guard let self else { return }
            let all = Self.profiles
            let next = all[(all.firstIndex(of: self.activeProfile).map { ($0 + 1) % all.count }) ?? 0]
            self.switchProfile(to: next)
        })
    }

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

// MARK: - Panel

struct DashboardPanelView: View {
    @ObservedObject var module: DashboardModule
    @ObservedObject private var weather: WeatherService
    @ObservedObject private var toggles: QuickToggleEngine
    @ObservedObject private var tracker: AppUsageTracker

    init(module: DashboardModule) {
        self.module = module
        self.weather = module.weather
        self.toggles = module.toggles
        self.tracker = module.screenTime
    }

    var body: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                EventsWidget(source: module.calendarSource)
                LauncherWidget(module: module, range: 0..<5, title: "Launcher")
                PomodoroMiniWidget(pomodoro: module.pomodoro)
                DayProgressWidget()
            }
            GridRow {
                QuickTogglesWidget(toggles: toggles)
                ScreenTimeWidget(tracker: tracker)
                ClockWeatherWidget(weather: weather, source: module.calendarSource)
                LauncherWidget(module: module, range: 5..<10, title: "Actions")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.trailing, 4)
    }
}

/// Uniform widget cell.
private struct WidgetCell<Content: View>: View {
    var title: String?
    var titleIcon: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let title {
                HStack(spacing: 4) {
                    if let titleIcon {
                        Image(systemName: titleIcon)
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                    Text(title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 88, maxHeight: 92, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
    }
}

private struct EventsWidget: View {
    let source: CalendarSource?

    var body: some View {
        WidgetCell(title: "Events", titleIcon: "calendar") {
            if let source, !source.events.isEmpty {
                EventsWidgetList(source: source)
            } else {
                Text("No events today")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct EventsWidgetList: View {
    @ObservedObject var source: CalendarSource

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(source.events.prefix(2)) { event in
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                    Text(
                        "\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))"
                    )
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct LauncherWidget: View {
    @ObservedObject var module: DashboardModule
    let range: Range<Int>
    let title: String

    var body: some View {
        WidgetCell(title: title, titleIcon: title == "Actions" ? "bolt.fill" : "square.grid.2x2") {
            let paths = Array(module.launcherPaths.dropFirst(range.lowerBound).prefix(range.count))
            HStack(spacing: 6) {
                ForEach(paths, id: \.self) { path in
                    Button { module.launch(path) } label: {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                            .resizable()
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .help(FileManager.default.displayName(atPath: path))
                    .contextMenu {
                        Button("Remove") { module.removeLauncher(path) }
                    }
                }
                if paths.count < range.count {
                    Button { module.addLauncher() } label: {
                        Image(systemName: "plus.circle.dashed")
                            .font(.system(size: 16))
                            .foregroundStyle(.tertiary)
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .help("Add app")
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }
}

private struct PomodoroMiniWidget: View {
    let pomodoro: PomodoroModule?

    var body: some View {
        WidgetCell(title: "Pomodoro", titleIcon: "timer") {
            if let pomodoro {
                PomodoroMiniContent(module: pomodoro)
            }
        }
    }
}

private struct PomodoroMiniContent: View {
    @ObservedObject var module: PomodoroModule

    var body: some View {
        let engine = module.engine
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(PomodoroPanelView.clock(engine.remaining(at: Date())))
                    .font(.system(size: 17, weight: .bold).monospacedDigit())
                Text(engine.phase == .work ? "WORK" : "BREAK")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            Text(engine.isRunning ? "Running" : "Paused")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            HStack(spacing: 10) {
                CircleIconButton(icon: "arrow.counterclockwise", size: 20) { module.reset() }
                CircleIconButton(
                    icon: engine.isRunning ? "pause.fill" : "play.fill",
                    size: 20, highlighted: true
                ) {
                    engine.isRunning ? module.pause() : module.start()
                }
            }
        }
    }
}

private struct DayProgressWidget: View {
    @AppStorage("dayprogress.start") private var startHour = 9
    @AppStorage("dayprogress.end") private var endHour = 18

    var body: some View {
        WidgetCell(title: "Day Progress", titleIcon: "chart.bar.fill") {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let fraction = DayProgress.fraction(
                    now: context.date, startHour: startHour, endHour: endHour
                )
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        if fraction == 1 {
                            Label("Done", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.green)
                        } else if let fraction {
                            Text("\(Int(fraction * 100))%")
                                .font(.system(size: 13, weight: .bold))
                        } else {
                            Text("Not started")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Text("\(startHour):00 – \(endHour):00")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                    ProgressView(value: fraction ?? 0)
                        .progressViewStyle(.linear)
                        .tint(Theme.accent)
                    if fraction == 1 {
                        Text("— You showed up. That counts. —")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

private struct QuickTogglesWidget: View {
    @ObservedObject var toggles: QuickToggleEngine

    var body: some View {
        WidgetCell(title: "Quick toggles", titleIcon: "sparkles") {
            let columns = Array(repeating: GridItem(.fixed(26), spacing: 7), count: 4)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 7) {
                ToggleCircle(icon: "moon.fill", label: "Dark Mode", isOn: toggles.darkMode) {
                    toggles.toggleDarkMode()
                }
                ToggleCircle(icon: "cup.and.saucer.fill", label: "Keep Awake", isOn: toggles.keepAwake) {
                    toggles.toggleKeepAwake()
                }
                ToggleCircle(
                    icon: "menubar.dock.rectangle", label: "Hide Desktop Icons",
                    isOn: toggles.desktopIconsHidden
                ) {
                    toggles.toggleDesktopIcons()
                }
                if toggles.nightShiftAvailable {
                    ToggleCircle(icon: "moon.stars.fill", label: "Night Shift", isOn: toggles.nightShift) {
                        toggles.toggleNightShift()
                    }
                }
                if toggles.trueToneAvailable {
                    ToggleCircle(icon: "display", label: "True Tone", isOn: toggles.trueTone) {
                        toggles.toggleTrueTone()
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }
}

private struct ToggleCircle: View {
    let icon: String
    let label: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(isOn ? Color.black : .white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(isOn ? Color.white : Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help(label)
    }
}

private struct ScreenTimeWidget: View {
    @ObservedObject var tracker: AppUsageTracker

    var body: some View {
        WidgetCell(title: "Screen Time", titleIcon: "hourglass") {
            let slices = tracker.todaySlices
            let total = max(slices.reduce(0) { $0 + $1.seconds }, 1)
            HStack(spacing: 8) {
                UsageDonut(slices: slices, total: total, centerText: ScreenTimeTile.duration(total))
                    .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(slices.prefix(3).enumerated()), id: \.offset) { index, slice in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(ScreenTimeTile.palette[index % ScreenTimeTile.palette.count])
                                .frame(width: 5, height: 5)
                            Text(ScreenTimeTile.appName(slice.bundleID))
                                .font(.system(size: 9))
                                .lineLimit(1)
                            Spacer(minLength: 2)
                            Text(ScreenTimeTile.duration(slice.seconds))
                                .font(.system(size: 8).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .onAppear { tracker.refresh() }
        }
    }
}

private struct ClockWeatherWidget: View {
    @ObservedObject var weather: WeatherService
    let source: CalendarSource?

    var body: some View {
        WidgetCell(title: nil) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(context.date.formatted(.dateTime.weekday(.wide)).uppercased())
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Theme.accent)
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text(context.date.formatted(.dateTime.day()))
                                    .font(.system(size: 16, weight: .bold))
                                Text(context.date.formatted(.dateTime.month(.abbreviated)))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(context.date.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 15, weight: .bold).monospacedDigit())
                    }
                    if let snapshot = weather.snapshot {
                        HStack(spacing: 4) {
                            Image(systemName: WeatherParser.symbol(for: snapshot.code))
                                .font(.system(size: 9))
                                .symbolRenderingMode(.multicolor)
                            Text("\(Int(snapshot.tempC.rounded()))°")
                                .font(.system(size: 10, weight: .semibold))
                            Text("H \(Int(snapshot.hiC.rounded()))° L \(Int(snapshot.loC.rounded()))°")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                            if let city = weather.locationName {
                                Text(city)
                                    .font(.system(size: 8))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    if let count = source?.events.count, count > 0 {
                        Text("Today · \(count) event\(count == 1 ? "" : "s")")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
        }
    }
}

struct UsageDonut: View {
    let slices: [UsageSlice]
    let total: TimeInterval
    var centerText: String?

    var body: some View {
        ZStack {
            var start = 0.0
            ForEach(Array(slices.enumerated()), id: \.offset) { index, slice in
                let sweep = slice.seconds / total
                let from = start
                let _ = { start += sweep }()
                Circle()
                    .trim(from: from, to: max(from, from + sweep - 0.004))
                    .stroke(
                        ScreenTimeTile.palette[index % ScreenTimeTile.palette.count],
                        style: StrokeStyle(lineWidth: 5, lineCap: .butt)
                    )
                    .rotationEffect(.degrees(-90))
            }
            if slices.isEmpty {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 5)
            }
            if let centerText {
                Text(centerText)
                    .font(.system(size: 7, weight: .bold))
            }
        }
    }
}
