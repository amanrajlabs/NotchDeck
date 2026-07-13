import SwiftUI

@MainActor
final class NotchViewModel: ObservableObject {
    enum NotchState { case collapsed, expanded }

    @Published var state: NotchState = .collapsed
    @Published var selectedModuleID: String?
    /// Set while a file drag hovers anywhere over the panel.
    @Published var isDropTargeted = false

    @Published var notchSize: CGSize
    let expandedSize = CGSize(width: 700, height: 348)

    private var hoverTask: Task<Void, Never>?

    init(notchSize: CGSize) {
        self.notchSize = notchSize
    }

    var panelSize: CGSize {
        CGSize(
            width: max(expandedSize.width, notchSize.width),
            height: max(expandedSize.height, notchSize.height)
        )
    }

    func setHover(_ hovering: Bool) {
        hoverTask?.cancel()
        hoverTask = Task { [weak self] in
            // Small debounce so grazing the notch doesn't flap the panel.
            try? await Task.sleep(for: .milliseconds(hovering ? 150 : 300))
            guard !Task.isCancelled, let self else { return }
            if !hovering && self.isDropTargeted { return }
            withAnimation(.snappy(duration: 0.3)) {
                self.state = hovering ? .expanded : .collapsed
            }
        }
    }

    func expand(showing moduleID: String? = nil) {
        hoverTask?.cancel()
        withAnimation(.snappy(duration: 0.3)) {
            if let moduleID { selectedModuleID = moduleID }
            state = .expanded
        }
    }

    func collapse() {
        hoverTask?.cancel()
        withAnimation(.snappy(duration: 0.3)) { state = .collapsed }
    }
}
