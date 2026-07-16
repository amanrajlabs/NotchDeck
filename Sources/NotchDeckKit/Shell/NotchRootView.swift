import SwiftUI
import UniformTypeIdentifiers

/// All concrete modules, so views can reach typed controllers.
@MainActor
struct ModuleSet {
    let dashboard: DashboardModule
    let media: MediaModule
    let hud: HUDModule
    let drop: DropModule
    let bluetooth: BluetoothModule
    let calendar: CalendarModule
    let system: SystemMonitorModule
    let screenTime: ScreenTimeModule
    let pomodoro: PomodoroModule
    let dayProgress: DayProgressModule
    let tasks: TasksModule
    let notes: NotesModule
    let notifications: NotificationsModule
    let translation: TranslationModule
    let git: GitModule
    let claude: ClaudeModule

    init(settings: SettingsStore) {
        dashboard = DashboardModule()
        media = MediaModule()
        hud = HUDModule(settings: settings)
        drop = DropModule()
        bluetooth = BluetoothModule()
        calendar = CalendarModule()
        system = SystemMonitorModule()
        screenTime = ScreenTimeModule(tracker: dashboard.screenTime)
        pomodoro = PomodoroModule()
        dayProgress = DayProgressModule()
        tasks = TasksModule()
        notes = NotesModule()
        notifications = NotificationsModule()
        translation = TranslationModule()
        git = GitModule()
        claude = ClaudeModule()
    }

    var all: [any NotchModule] {
        [dashboard, media, calendar, tasks, notes, pomodoro, dayProgress, notifications, git, claude, translation, system, screenTime, drop, bluetooth, hud]
    }
}

struct NotchRootView: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var registry: ModuleRegistry
    let modules: ModuleSet

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if vm.snapZones != nil {
                    SnapZoneStripView(vm: vm)
                        .transition(.opacity)
                } else if vm.state == .expanded {
                    ExpandedView(vm: vm, registry: registry, modules: modules)
                        .transition(.scale(scale: 0.85, anchor: .top).combined(with: .opacity))
                } else {
                    CollapsedStripView(vm: vm, registry: registry, modules: modules)
                        .transition(.opacity)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onDrop(of: [UTType.fileURL], delegate: NotchDropDelegate(vm: vm, drop: modules.drop))
    }
}

// MARK: - Collapsed strip

struct CollapsedStripView: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var registry: ModuleRegistry
    let modules: ModuleSet
    // Observe every controller that can add/remove a live activity, so the
    // strip re-renders the moment their state changes.
    @ObservedObject private var hud: HUDController
    @ObservedObject private var media: MediaController
    @ObservedObject private var calendarSource: CalendarSource
    @ObservedObject private var bluetooth: BluetoothModule
    @ObservedObject private var pomodoro: PomodoroModule

    init(vm: NotchViewModel, registry: ModuleRegistry, modules: ModuleSet) {
        self.vm = vm
        self.registry = registry
        self.modules = modules
        self.hud = modules.hud.controller
        self.media = modules.media.controller
        self.calendarSource = modules.calendar.source
        self.bluetooth = modules.bluetooth
        self.pomodoro = modules.pomodoro
    }

    static let extensionWidth: CGFloat = 120

    var body: some View {
        // The only timer this view introduces: a 6 s UI-only tick that
        // drives which live activity occupies the trailing slot. It only
        // exists while the collapsed strip is on-screen and is coalesced
        // by SwiftUI — no polling of any module state happens here.
        TimelineView(.periodic(from: .now, by: 6)) { context in
            strip(tick: Int(context.date.timeIntervalSinceReferenceDate / 6))
        }
    }

    private func strip(tick: Int) -> some View {
        let leading = leadingActivity
        let trailing = trailingActivity(tick: tick)
        let leadW: CGFloat = leading == nil ? 0 : Self.extensionWidth
        let trailW: CGFloat = trailing == nil ? 0 : Self.extensionWidth
        let width = vm.notchSize.width + leadW + trailW

        return NotchShape()
            .fill(Color.black)
            .frame(width: width, height: vm.notchSize.height)
            .overlay {
                HStack(spacing: 0) {
                    Group {
                        if let leading { leading } else { Color.clear }
                    }
                    .frame(width: max(leadW, 1), height: vm.notchSize.height)
                    Color.clear.frame(width: vm.notchSize.width)
                    Group {
                        if let trailing { trailing } else { Color.clear }
                    }
                    .frame(width: max(trailW, 1), height: vm.notchSize.height)
                }
            }
            .clipShape(NotchShape())
            // Keep the notch-covering middle glued to the physical notch.
            .offset(x: (trailW - leadW) / 2)
            .contentShape(NotchShape())
            .onHover { vm.setHover($0) }
            .onTapGesture { vm.expand() }
            .animation(.snappy(duration: 0.25), value: leadW + trailW)
    }

    private var leadingActivity: AnyView? {
        guard registry.enabledIDs.contains(modules.media.id) else { return nil }
        return modules.media.liveActivityView()
    }

    /// HUD interrupts always win; otherwise round-robins through every
    /// enabled module with a live activity or glance, 6 s per candidate.
    private func trailingActivity(tick: Int) -> AnyView? {
        if hud.event != nil, registry.enabledIDs.contains(modules.hud.id) {
            return AnyView(HUDLiveView(controller: hud))
        }
        var candidates: [AnyView] = []
        if registry.enabledIDs.contains(modules.pomodoro.id),
           let v = modules.pomodoro.liveActivityView() { candidates.append(v) }
        if registry.enabledIDs.contains(modules.calendar.id),
           let v = modules.calendar.liveActivityView() { candidates.append(v) }
        if registry.enabledIDs.contains(modules.bluetooth.id),
           let v = modules.bluetooth.liveActivityView() { candidates.append(v) }
        if registry.enabledIDs.contains(modules.notifications.id),
           let v = modules.notifications.glanceView() { candidates.append(v) }
        guard let index = LiveRotation.pick(count: candidates.count, tick: tick) else { return nil }
        return candidates[index]
    }
}

// MARK: - Expanded panel chrome

struct ExpandedView: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var registry: ModuleRegistry
    let modules: ModuleSet

    var body: some View {
        let panelModules = registry.panelModules
        let selectedID = vm.selectedModuleID ?? panelModules.first?.id
        let selected = panelModules.first(where: { $0.id == selectedID })
        let contentHeight = min(selected?.preferredHeight ?? 170, Theme.maxContentHeight)
        let panelHeight = Theme.headerHeight + contentHeight + 10

        VStack(spacing: Theme.dockGap) {
            panel(selected: selected, height: panelHeight)
                .frame(width: Theme.panelWidth, height: panelHeight)
            ModuleDock(
                modules: panelModules,
                selectedID: selectedID
            ) { vm.selectedModuleID = $0 }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .onHover { vm.setHover($0) }
        .preferredColorScheme(.dark)
    }

    private func panel(selected: (any NotchModule)?, height: CGFloat) -> some View {
        let shape = NotchShape(topRadius: 8, bottomRadius: 18)
        return shape
            .fill(Theme.panelGradient)
            .overlay(shape.stroke(Color.white.opacity(0.07), lineWidth: 1))
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    header(selected: selected)
                    HStack(alignment: .top, spacing: 0) {
                        Group {
                            if let selected {
                                selected.panelView()
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                Text("Enable modules in Settings")
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                        .padding(.leading, 16)
                        .padding(.trailing, 6)
                        .padding(.bottom, 10)
                        QuickRail(
                            modules: registry.panelModules,
                            selectedID: selected?.id
                        ) { vm.selectedModuleID = $0 }
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                CircleIconButton(icon: "arrow.down.forward.and.arrow.up.backward", size: 22) {
                    vm.collapse()
                }
                .padding(8)
            }
            .clipShape(shape)
            .contentShape(shape)
            .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
    }

    private func header(selected: (any NotchModule)?) -> some View {
        let sideWidth = (Theme.panelWidth - vm.notchSize.width) / 2
        return HStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(selected?.name ?? "NotchDeck")
                    .font(.system(size: 13, weight: .bold))
                if let badge = selected?.headerBadge() {
                    badge
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 14)
            .frame(width: sideWidth, alignment: .leading)
            Color.clear.frame(width: vm.notchSize.width)
            HStack(spacing: 7) {
                Spacer(minLength: 0)
                if let actions = selected?.headerActions() {
                    actions
                }
                CircleIconButton(icon: "info", size: 20) {
                    SettingsWindowController.shared.show()
                }
                .help("Settings")
            }
            .padding(.trailing, 12)
            .frame(width: sideWidth, alignment: .trailing)
        }
        .frame(height: Theme.headerHeight)
    }
}

/// Floating row of circular module buttons below the panel.
struct ModuleDock: View {
    let modules: [any NotchModule]
    let selectedID: String?
    let select: (String) -> Void

    var body: some View {
        HStack(spacing: 9) {
            ForEach(modules, id: \.id) { module in
                DockButton(
                    icon: module.icon,
                    name: module.name,
                    isSelected: module.id == selectedID
                ) { select(module.id) }
            }
        }
        .frame(height: Theme.dockHeight)
    }
}

struct DockButton: View {
    let icon: String
    let name: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? Color.black : .white)
                .frame(width: 34, height: 34)
                .background(
                    Circle().fill(
                        isSelected
                            ? Color.white
                            : Color.black.opacity(hovering ? 0.75 : 0.9)
                    )
                )
                .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 1))
                .scaleEffect(hovering && !isSelected ? 1.1 : 1)
                .animation(.snappy(duration: 0.15), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(name)
    }
}

/// Tiny quick-switch icons along the panel's right edge.
struct QuickRail: View {
    let modules: [any NotchModule]
    let selectedID: String?
    let select: (String) -> Void

    var body: some View {
        VStack(spacing: 9) {
            ForEach(Array(modules.filter { $0.id != selectedID }.prefix(5)), id: \.id) { module in
                RailButton(icon: module.icon, name: module.name) { select(module.id) }
            }
            Spacer(minLength: 0)
        }
        .frame(width: 26)
        .padding(.top, 4)
        .padding(.trailing, 4)
    }
}

struct RailButton: View {
    let icon: String
    let name: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(hovering ? 0.95 : 0.35))
                .frame(width: 18, height: 16)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(name)
    }
}

// MARK: - Drop delegate

struct NotchDropDelegate: DropDelegate {
    let vm: NotchViewModel
    let drop: DropModule

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.fileURL])
    }

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            vm.isDropTargeted = true
            vm.expand(showing: DropModule.moduleID)
        }
    }

    func dropExited(info: DropInfo) {
        MainActor.assumeIsolated { vm.isDropTargeted = false }
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [UTType.fileURL])
        guard !providers.isEmpty else { return false }
        return MainActor.assumeIsolated {
            vm.isDropTargeted = false
            drop.addPending(providers)
            return true
        }
    }
}
