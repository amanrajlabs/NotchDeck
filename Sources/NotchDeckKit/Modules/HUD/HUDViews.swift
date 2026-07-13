import SwiftUI

@MainActor
final class HUDModule: NotchModule {
    static let moduleID = "hud"
    let id = HUDModule.moduleID
    let name = "Volume & Brightness HUD"
    let icon = "speaker.wave.2.fill"
    let hasPanel = false
    let controller: HUDController

    init(settings: SettingsStore) {
        controller = HUDController(settings: settings)
    }

    func activate() { controller.activate() }
    func deactivate() { controller.deactivate() }

    func panelView() -> AnyView { AnyView(EmptyView()) }

    func liveActivityView() -> AnyView? {
        guard controller.event != nil else { return nil }
        return AnyView(HUDLiveView(controller: controller))
    }
}

struct HUDLiveView: View {
    @ObservedObject var controller: HUDController

    var body: some View {
        if let event = controller.event {
            HStack(spacing: 8) {
                Image(systemName: symbol(for: event))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 16)
                ProgressView(value: event.muted ? 0 : event.level)
                    .progressViewStyle(.linear)
                    .tint(.white)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .transition(.opacity)
        }
    }

    private func symbol(for event: HUDEvent) -> String {
        switch event.kind {
        case .brightness:
            return "sun.max.fill"
        case .volume:
            if event.muted || event.level == 0 { return "speaker.slash.fill" }
            if event.level < 0.34 { return "speaker.wave.1.fill" }
            if event.level < 0.67 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        }
    }
}
