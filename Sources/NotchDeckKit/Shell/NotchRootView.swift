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
    let pomodoro: PomodoroModule
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
        pomodoro = PomodoroModule()
        tasks = TasksModule()
        notes = NotesModule()
        notifications = NotificationsModule()
        translation = TranslationModule()
        git = GitModule()
        claude = ClaudeModule()
    }

    var all: [any NotchModule] {
        [dashboard, media, calendar, tasks, notes, pomodoro, notifications, git, claude, translation, system, drop, bluetooth, hud]
    }
}

struct NotchRootView: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var registry: ModuleRegistry
    let modules: ModuleSet

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if vm.state == .expanded {
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
        let leading = leadingActivity
        let trailing = trailingActivity
        let leadW: CGFloat = leading == nil ? 0 : Self.extensionWidth
        let trailW: CGFloat = trailing == nil ? 0 : Self.extensionWidth
        let width = vm.notchSize.width + leadW + trailW

        NotchShape()
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

    private var trailingActivity: AnyView? {
        if hud.event != nil, registry.enabledIDs.contains(modules.hud.id) {
            return AnyView(HUDLiveView(controller: hud))
        }
        if registry.enabledIDs.contains(modules.pomodoro.id),
           let pomodoro = modules.pomodoro.liveActivityView() {
            return pomodoro
        }
        if registry.enabledIDs.contains(modules.calendar.id),
           let cal = modules.calendar.liveActivityView() {
            return cal
        }
        if registry.enabledIDs.contains(modules.bluetooth.id),
           let bt = modules.bluetooth.liveActivityView() {
            return bt
        }
        return nil
    }
}

// MARK: - Expanded dashboard

struct ExpandedView: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var registry: ModuleRegistry
    let modules: ModuleSet

    var body: some View {
        let panelModules = registry.panelModules
        let selectedID = vm.selectedModuleID ?? panelModules.first?.id
        let sideWidth = (vm.expandedSize.width - vm.notchSize.width) / 2
        // Tabs flow around the physical notch: first half left, rest right.
        let splitIndex = (panelModules.count + 1) / 2
        let leftTabs = Array(panelModules.prefix(splitIndex))
        let rightTabs = Array(panelModules.dropFirst(splitIndex))

        NotchShape(topRadius: 8, bottomRadius: 22)
            .fill(Color.black)
            .frame(width: vm.expandedSize.width, height: vm.expandedSize.height)
            .overlay(alignment: .top) {
                VStack(spacing: 4) {
                    // Header row flanks the physical notch.
                    HStack(spacing: 0) {
                        HStack(spacing: 5) {
                            ForEach(leftTabs, id: \.id) { module in
                                TabButton(
                                    icon: module.icon,
                                    name: module.name,
                                    isSelected: module.id == selectedID
                                ) { vm.selectedModuleID = module.id }
                            }
                        }
                        .frame(width: sideWidth, alignment: .leading)
                        .padding(.leading, 4)
                        Color.clear.frame(width: vm.notchSize.width)
                        HStack(spacing: 5) {
                            ForEach(rightTabs, id: \.id) { module in
                                TabButton(
                                    icon: module.icon,
                                    name: module.name,
                                    isSelected: module.id == selectedID
                                ) { vm.selectedModuleID = module.id }
                            }
                            Spacer()
                            Button {
                                SettingsWindowController.shared.show()
                            } label: {
                                Image(systemName: "gearshape.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .frame(width: sideWidth, alignment: .trailing)
                        .padding(.trailing, 12)
                    }
                    .frame(height: max(vm.notchSize.height, 30))

                    if let selected = panelModules.first(where: { $0.id == selectedID }) {
                        selected.panelView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                    } else {
                        Text("Enable modules in Settings")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .clipShape(NotchShape(topRadius: 8, bottomRadius: 22))
            .contentShape(NotchShape(topRadius: 8, bottomRadius: 22))
            .onHover { vm.setHover($0) }
            .preferredColorScheme(.dark)
    }
}

struct TabButton: View {
    let icon: String
    var name = ""
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? .white : Color.white.opacity(hovering ? 0.8 : 0.45))
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected
                            ? Color.white.opacity(0.15)
                            : Color.white.opacity(hovering ? 0.08 : 0))
                )
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
