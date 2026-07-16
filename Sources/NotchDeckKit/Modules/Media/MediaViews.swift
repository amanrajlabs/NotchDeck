import SwiftUI

@MainActor
final class MediaModule: NotchModule {
    static let moduleID = "media"
    let id = MediaModule.moduleID
    let name = "Media"
    let icon = "music.note"
    let hasPanel = true
    let controller = MediaController()

    var preferredHeight: CGFloat { 172 }

    func activate() { controller.activate() }
    func deactivate() { controller.deactivate() }

    func panelView() -> AnyView { AnyView(MediaPanelView(controller: controller)) }

    func headerBadge() -> AnyView? {
        guard let track = controller.track else { return nil }
        let label: String
        switch track.player {
        case .spotify: label = "Spotify"
        case .music: label = "Apple Music"
        case .system: label = track.appName ?? "Now Playing"
        }
        return AnyView(HeaderPill(text: label, icon: "music.note"))
    }

    func liveActivityView() -> AnyView? {
        guard controller.track != nil else { return nil }
        return AnyView(MediaLiveActivityView(controller: controller))
    }
}

struct MediaLiveActivityView: View {
    @ObservedObject var controller: MediaController
    @State private var hovering = false
    @AppStorage("mediaHoverControls") private var mediaHoverControls = true
    @AppStorage("mediaVisualization") private var mediaVisualization = "bars"

    var body: some View {
        HStack(spacing: 8) {
            ArtworkView(image: controller.artwork, size: 20)
            if hovering && mediaHoverControls {
                HStack(spacing: 7) {
                    Button { controller.previousTrack() } label: {
                        Image(systemName: "backward.fill").font(.system(size: 9))
                    }
                    Button { controller.playPause() } label: {
                        Image(systemName: controller.track?.isPlaying == true
                              ? "pause.fill" : "play.fill").font(.system(size: 10))
                    }
                    Button { controller.nextTrack() } label: {
                        Image(systemName: "forward.fill").font(.system(size: 9))
                    }
                }
                .buttonStyle(.plain)
            } else if mediaVisualization == "spectrum" {
                SpectrumBars(isPlaying: controller.track?.isPlaying == true)
                    .frame(width: 30, height: 14)
            } else {
                EqualizerBars(isPlaying: controller.track?.isPlaying == true)
                    .frame(width: 16, height: 14)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering = $0 }
    }
}

struct MediaPanelView: View {
    @ObservedObject var controller: MediaController
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false

    var body: some View {
        Group {
            if let track = controller.track {
                HStack(alignment: .top, spacing: 22) {
                    playerColumn(track: track)
                        .frame(width: 300)
                    rightColumn(track: track)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("Nothing playing")
                        .foregroundStyle(.secondary)
                    Text("Play something in Spotify, Music, or your browser")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { controller.isPanelVisible = true }
        .onDisappear { controller.isPanelVisible = false }
    }

    private func playerColumn(track: TrackInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                ArtworkView(image: controller.artwork, size: 74)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.system(size: 15, weight: .bold))
                        .lineLimit(2)
                    Text(subtitle(for: track))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            scrubber(duration: track.duration)
            transport(track: track)
        }
    }

    private func rightColumn(track: TrackInfo) -> some View {
        ZStack(alignment: .bottomLeading) {
            // Decorative level bars along the bottom, like a waveform bed.
            if track.isPlaying {
                EqualizerBars(isPlaying: true)
                    .frame(width: 220, height: 46)
                    .opacity(0.18)
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionCaption(text: "Now playing from")
                Text(sourceName(for: track))
                    .font(.system(size: 13, weight: .semibold))
                if !track.album.isEmpty {
                    SectionCaption(text: "Album")
                        .padding(.top, 6)
                    Text(track.album)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func sourceName(for track: TrackInfo) -> String {
        switch track.player {
        case .spotify: "Spotify"
        case .music: "Apple Music"
        case .system: track.appName ?? "System player"
        }
    }

    private func scrubber(duration: TimeInterval) -> some View {
        VStack(spacing: 3) {
            // Seek once on release — seeking live during the drag spams
            // AppleEvents (or helper processes) dozens of times per drag.
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubValue : min(controller.position, max(duration, 1)) },
                    set: { scrubValue = $0 }
                ),
                in: 0...max(duration, 1),
                onEditingChanged: { editing in
                    if editing {
                        scrubValue = controller.position
                        isScrubbing = true
                    } else {
                        isScrubbing = false
                        controller.seek(to: scrubValue)
                    }
                }
            )
            .controlSize(.mini)
            .tint(.white)
            HStack {
                Text(Self.timeString(isScrubbing ? scrubValue : controller.position))
                Spacer()
                Text(Self.timeString(duration))
            }
            .font(.system(size: 9).monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func transport(track: TrackInfo) -> some View {
        HStack(spacing: 20) {
            if track.player != .system {
                Button { controller.toggleShuffle() } label: {
                    Image(systemName: "shuffle").font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Button { controller.previousTrack() } label: {
                Image(systemName: "backward.fill").font(.system(size: 15))
            }
            Button { controller.playPause() } label: {
                Image(systemName: track.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.white.opacity(0.92)))
            }
            Button { controller.nextTrack() } label: {
                Image(systemName: "forward.fill").font(.system(size: 15))
            }
            if track.player != .system {
                Button { controller.toggleRepeat() } label: {
                    Image(systemName: "repeat").font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    static func timeString(_ t: TimeInterval) -> String {
        let total = Int(t.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

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

/// Denser, center-weighted animated bars — a faux spectrum (no audio taps).
/// Uses TimelineView like EqualizerBars used to before it moved to a
/// CALayer-driven implementation; paused entirely while not playing so it
/// costs zero CPU at idle.
struct SpectrumBars: View {
    let isPlaying: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: !isPlaying)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 1.5) {
                ForEach(0..<12, id: \.self) { i in
                    let center = abs(Double(i) - 5.5) / 5.5 // 0 at center, 1 at edges
                    let wave = (sin(phase * 3 + Double(i) * 1.1) + 1) / 2
                    let height = isPlaying ? 3 + wave * 11 * (1.1 - center) : 2
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: 2, height: height)
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
        // Wider hosts get more bars (waveform bed); small hosts get 4.
        let count = max(4, Int(bounds.width / 12))
        let spacing: CGFloat = count > 8 ? 4 : 2
        let barWidth = (bounds.width - spacing * CGFloat(count - 1)) / CGFloat(count)
        for i in 0..<count {
            let bar = CALayer()
            bar.backgroundColor = NSColor.systemGreen.cgColor
            bar.cornerRadius = min(barWidth / 2, 3)
            bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: bounds.height)
            bar.anchorPoint = CGPoint(x: 0.5, y: 0) // grow from the bottom
            bar.position = CGPoint(x: CGFloat(i) * (barWidth + spacing) + barWidth / 2, y: 0)

            let animation = CABasicAnimation(keyPath: "transform.scale.y")
            animation.fromValue = 0.25
            animation.toValue = Self.peaks[i % Self.peaks.count]
            animation.duration = 0.45 + Double(i % 4) * 0.1
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bar.add(animation, forKey: "eq")
            layer.addSublayer(bar)
        }
    }
}
