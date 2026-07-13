import SwiftUI

@MainActor
final class MediaModule: NotchModule {
    static let moduleID = "media"
    let id = MediaModule.moduleID
    let name = "Media"
    let icon = "music.note"
    let hasPanel = true
    let controller = MediaController()

    func activate() { controller.activate() }
    func deactivate() { controller.deactivate() }

    func panelView() -> AnyView { AnyView(MediaPanelView(controller: controller)) }

    func liveActivityView() -> AnyView? {
        guard controller.track != nil else { return nil }
        return AnyView(MediaLiveActivityView(controller: controller))
    }
}

struct MediaLiveActivityView: View {
    @ObservedObject var controller: MediaController

    var body: some View {
        HStack(spacing: 8) {
            ArtworkView(image: controller.artwork, size: 20)
            EqualizerBars(isPlaying: controller.track?.isPlaying == true)
                .frame(width: 16, height: 14)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MediaPanelView: View {
    @ObservedObject var controller: MediaController

    var body: some View {
        Group {
            if let track = controller.track {
                HStack(spacing: 16) {
                    ArtworkView(image: controller.artwork, size: 130)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(track.title)
                            .font(.system(size: 16, weight: .semibold))
                            .lineLimit(1)
                        Text(subtitle(for: track))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        scrubber(duration: track.duration)
                        controls(isPlaying: track.isPlaying)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("Nothing playing")
                        .foregroundStyle(.secondary)
                    Text("Start Spotify or Apple Music")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { controller.isPanelVisible = true }
        .onDisappear { controller.isPanelVisible = false }
    }

    private func scrubber(duration: TimeInterval) -> some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { min(controller.position, max(duration, 1)) },
                    set: { controller.seek(to: $0) }
                ),
                in: 0...max(duration, 1)
            )
            .controlSize(.mini)
            HStack {
                Text(Self.timeString(controller.position))
                Spacer()
                Text(Self.timeString(duration))
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func controls(isPlaying: Bool) -> some View {
        HStack(spacing: 26) {
            Button { controller.previousTrack() } label: {
                Image(systemName: "backward.fill").font(.system(size: 16))
            }
            Button { controller.playPause() } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22))
            }
            Button { controller.nextTrack() } label: {
                Image(systemName: "forward.fill").font(.system(size: 16))
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    static func timeString(_ t: TimeInterval) -> String {
        let total = Int(t.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: size > 40 ? 10 : 5)
                    .fill(Color.white.opacity(0.1))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: size / 3))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 40 ? 10 : 5))
    }
}

/// Four animated bars shown while music plays. The animated variant exists
/// only while playing — a lingering repeatForever animation otherwise keeps
/// SwiftUI re-rendering every frame at idle.
struct EqualizerBars: View {
    let isPlaying: Bool

    static let phases: [Double] = [0.9, 0.5, 1.0, 0.65]

    var body: some View {
        if isPlaying {
            AnimatedEqualizerBars()
        } else {
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { _ in
                    Capsule()
                        .fill(Color.green.opacity(0.7))
                        .frame(maxHeight: .infinity)
                        .scaleEffect(y: 0.25, anchor: .bottom)
                }
            }
        }
    }
}

/// Core Animation bars: CABasicAnimations run in the window server, so the
/// app spends zero CPU per frame. SwiftUI-driven animation here (whether
/// repeatForever or TimelineView) re-runs the view graph every tick and
/// costs several percent CPU for the life of the track.
private struct AnimatedEqualizerBars: NSViewRepresentable {
    func makeNSView(context: Context) -> EqualizerLayerView { EqualizerLayerView() }
    func updateNSView(_ nsView: EqualizerLayerView, context: Context) {}
}

final class EqualizerLayerView: NSView {
    private static let peaks: [CGFloat] = [0.9, 0.55, 1.0, 0.7]
    private var builtSize: CGSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unsupported") }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0, bounds.size != builtSize else { return }
        builtSize = bounds.size
        rebuildBars()
    }

    private func rebuildBars() {
        guard let layer else { return }
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        let count = Self.peaks.count
        let spacing: CGFloat = 2
        let barWidth = (bounds.width - spacing * CGFloat(count - 1)) / CGFloat(count)
        for i in 0..<count {
            let bar = CALayer()
            bar.backgroundColor = NSColor.systemGreen.cgColor
            bar.cornerRadius = barWidth / 2
            bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: bounds.height)
            bar.anchorPoint = CGPoint(x: 0.5, y: 0) // grow from the bottom
            bar.position = CGPoint(x: CGFloat(i) * (barWidth + spacing) + barWidth / 2, y: 0)

            let animation = CABasicAnimation(keyPath: "transform.scale.y")
            animation.fromValue = 0.25
            animation.toValue = Self.peaks[i]
            animation.duration = 0.45 + Double(i) * 0.1
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bar.add(animation, forKey: "eq")
            layer.addSublayer(bar)
        }
    }
}

extension MediaPanelView {
    /// "Artist", "Artist — Chrome", or "Chrome" for browser tracks.
    func subtitle(for track: TrackInfo) -> String {
        switch (track.artist.isEmpty, track.appName) {
        case (false, .some(let app)) where track.player == .system:
            return "\(track.artist) — \(app)"
        case (false, _):
            return track.artist
        case (true, .some(let app)):
            return app
        case (true, nil):
            return ""
        }
    }
}
