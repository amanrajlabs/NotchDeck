import SwiftUI

/// Tile row hanging from the notch while a window drag hovers the top edge.
struct SnapZoneStripView: View {
    @ObservedObject var vm: NotchViewModel

    var body: some View {
        if let layouts = vm.snapZones {
            VStack(spacing: 0) {
                NotchShape()
                    .fill(Color.black)
                    .frame(width: vm.notchSize.width, height: vm.notchSize.height)
                HStack(spacing: SnapZoneMath.tileSpacing) {
                    ForEach(Array(layouts.enumerated()), id: \.offset) { index, layout in
                        VStack(spacing: 3) {
                            Image(systemName: layout.icon).font(.system(size: 16))
                            Text(layout.title).font(.system(size: 7))
                        }
                        .frame(width: SnapZoneMath.tileSize.width, height: SnapZoneMath.tileSize.height)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(vm.snapHighlight == index ? Theme.accent.opacity(0.55) : Theme.card)
                        )
                    }
                }
                .padding(SnapZoneMath.stripPadding)
                .background(
                    RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.92))
                )
            }
            .foregroundStyle(.white)
            .transition(.opacity)
        }
    }
}
