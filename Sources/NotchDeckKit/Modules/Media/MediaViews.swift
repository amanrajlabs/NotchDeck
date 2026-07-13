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

/// Rate-capped timeline (~8 fps) instead of repeatForever: a repeatForever
/// animation ticks the whole hosting view at display refresh (120 Hz here)
/// and costs ~9% CPU; this stays under 1%.
private struct AnimatedEqualizerBars: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule()
                        .fill(Color.green)
                        .frame(maxHeight: .infinity)
                        .scaleEffect(y: Self.level(bar: i, at: t), anchor: .bottom)
                }
            }
        }
    }

    /// Layered per-bar sines for organic motion, in 0.25...1.0.
    static func level(bar: Int, at t: Double) -> Double {
        let wave = 0.5 + 0.5 * sin(t * (2.2 + Double(bar) * 0.35) + Double(bar) * 1.7)
        return 0.25 + 0.75 * wave
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
