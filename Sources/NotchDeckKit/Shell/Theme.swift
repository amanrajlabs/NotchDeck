import SwiftUI

/// Shared look for the expanded panel, matching the studied design language.
enum Theme {
    static let panelWidth: CGFloat = 660
    static let dockHeight: CGFloat = 40
    static let dockGap: CGFloat = 10
    static let headerHeight: CGFloat = 34
    static let maxContentHeight: CGFloat = 250

    static let panelTop = Color(red: 0.105, green: 0.105, blue: 0.12)
    static let panelBottom = Color(red: 0.02, green: 0.02, blue: 0.03)
    static let accent = Color(red: 0.35, green: 0.62, blue: 1.0) // links, times
    static let card = Color.white.opacity(0.07)
    static let cardHover = Color.white.opacity(0.12)

    static var panelGradient: LinearGradient {
        LinearGradient(
            colors: [panelTop, panelBottom],
            startPoint: .top, endPoint: .bottom
        )
    }
}

/// Tiny uppercase gray label ("LYRICS", "DUE DATE", …).
struct SectionCaption: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 8.5, weight: .semibold))
            .kerning(0.5)
            .foregroundStyle(Color.white.opacity(0.4))
    }
}

/// Small rounded badge next to the header title.
struct HeaderPill: View {
    let text: String
    var icon: String?
    var action: (() -> Void)?

    var body: some View {
        Button {
            action?()
        } label: {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 9))
                }
                Text(text).font(.system(size: 10, weight: .semibold))
                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }
}

/// Circular header/dock icon button.
struct CircleIconButton: View {
    let icon: String
    var size: CGFloat = 22
    var highlighted = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(highlighted ? Color.black : .white)
                .frame(width: size, height: size)
                .background(
                    Circle().fill(
                        highlighted
                            ? Color.white
                            : Color.white.opacity(hovering ? 0.22 : 0.12)
                    )
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Row container with the card background used across module lists.
struct CardRow<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(hovering ? Theme.cardHover : Theme.card)
            )
            .onHover { hovering = $0 }
    }
}
