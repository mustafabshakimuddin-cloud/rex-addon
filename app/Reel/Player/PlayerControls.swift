import SwiftUI
import AVKit
import AetherEngine

/// The player's parts: the scrubber, the startup cover, chips, skip and Up Next helpers.
// MARK: - Pieces

/// The scrubber and time labels: the only part of the controls that follows the clock.
struct TimelineBar: View {
    var time: PlaybackTime
    let duration: Double
    let chapters: [ChapterInfo]
    let preview: (Double) async -> CGImage?
    let scrubbing: Double?
    let onChange: (Double) -> Void
    let onCommit: (Double) -> Void

    var body: some View {
        let shown = scrubbing ?? time.currentTime
        VStack(spacing: 12) {
            Scrubber(value: shown, buffered: time.buffered, duration: duration,
                     marks: chapters.map(\.startSeconds).filter { $0 > 1 }, onChange: onChange, onCommit: onCommit)
                .overlay(alignment: .bottomLeading) {
                    if let scrubbing, duration > 0 {
                        GeometryReader { proxy in
                            let x = proxy.size.width * CGFloat(min(max(scrubbing / duration, 0), 1))
                            ScrubPreview(seconds: scrubbing, provider: preview)
                                .fixedSize()
                                .position(x: min(max(x, 88), proxy.size.width - 88), y: -78)
                        }
                    }
                }
            HStack {
                Text(PlayerView.clock(shown))
                Spacer()
                Text("-" + PlayerView.clock(max(0, duration - shown)))
            }
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))
        }
    }
}

/// Shown until the engine has a first picture: the title's art, blurred, with a spinner.
struct StartupCover: View {
    let session: PlayerSession

    var body: some View {
        ZStack {
            RemoteImage(url: session.target.episode?.thumbnail ?? session.target.item.background, targetWidth: 200)
                .blur(radius: 30)
                .overlay(Color.black.opacity(0.55))
                .ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView().largeControl().tint(.white)
                Text("Opening \(session.target.displayTitle)").font(.headline)
                Text([session.source.quality, session.source.size].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.white.opacity(0.7))
            }
            .padding()
        }
        .allowsHitTesting(false)
    }
}

struct PlayerChip: View {
    let text: String
    var highlighted = false

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(highlighted ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.white.opacity(0.16)),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .lineLimit(1)
    }
}

/// Icon only on narrow windows, icon and title when there is room.
struct AdaptiveLabelStyle: LabelStyle {
    let showsTitle: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
            if showsTitle { configuration.title }
        }
    }
}

/// A scrubber with the buffered range drawn behind the playhead. Dragging previews the time and
/// seeks on release, so a drag across the film costs one seek, not hundreds.
struct Scrubber: View {
    let value: Double
    let buffered: Double
    let duration: Double
    /// Chapter starts, drawn as small gaps in the track.
    var marks: [Double] = []
    let onChange: (Double) -> Void
    let onCommit: (Double) -> Void
    @State private var dragging = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let span = max(duration, 1)
            let progress = CGFloat(min(max(value / span, 0), 1))
            let loaded = CGFloat(min(max(buffered / span, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule().fill(.white.opacity(0.32)).frame(width: width * max(loaded, progress))
                Capsule().fill(Theme.accentGradient).frame(width: width * progress)
                ForEach(marks, id: \.self) { mark in
                    Rectangle().fill(.black.opacity(0.55))
                        .frame(width: 2)
                        .offset(x: width * CGFloat(min(max(mark / span, 0), 1)) - 1)
                }
                Circle()
                    .fill(.white)
                    .frame(width: dragging ? 22 : 14, height: dragging ? 22 : 14)
                    .shadow(radius: 3)
                    .offset(x: width * progress - (dragging ? 11 : 7))
            }
            .frame(height: dragging ? 8 : 5)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            #if os(iOS)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        dragging = true
                        onChange(Double(min(max(gesture.location.x / width, 0), 1)) * span)
                    }
                    .onEnded { gesture in
                        dragging = false
                        onCommit(Double(min(max(gesture.location.x / width, 0), 1)) * span)
                    }
            )
            #endif
            .animation(.snappy(duration: 0.2), value: dragging)
        }
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(PlayerView.clock(value))
        .accessibilityAdjustableAction { direction in
            // About a fortieth of the film per swipe: 30 s steps are tiny across three hours.
            let step = min(max(duration / 40, 10), 300)
            onCommit(value + (direction == .increment ? step : -step))
        }
    }
}

#if os(iOS)
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = UIColor(Theme.accent)
        view.prioritizesVideoDevices = true
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif

/// Two chevrons on the side a double tap skipped.
struct SkipFlashView: View {
    let forward: Bool
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: forward ? "goforward.10" : "gobackward.10").font(.system(size: 34, weight: .semibold))
            Text(forward ? "+10 s" : "−10 s").font(.caption.weight(.bold))
        }
        .foregroundStyle(.white)
        .padding(22)
        .glassEffect(.regular, in: .circle)
    }
}

/// Skips intros and recaps by itself, once per chapter, when Settings asks for it.
struct AutoSkipper: View {
    var time: PlaybackTime
    let chapters: [ChapterInfo]
    let duration: Double
    let intro: Bool
    let recap: Bool
    let skip: (Double) -> Void
    @State private var skipped: Set<Double> = []

    var body: some View {
        let now = time.currentTime
        let chapter = chapters.first { now >= $0.startSeconds + 0.5 && now < $0.startSeconds + $0.durationSeconds - 3 }
        Color.clear.frame(width: 0, height: 0)
            .onChange(of: chapter?.startSeconds) { _, start in
                guard let chapter, let start, !skipped.contains(start) else { return }
                let kind = ChapterKind(chapter.name)
                guard (kind == .intro && intro) || (kind == .recap && recap) else { return }
                skipped.insert(start)
                skip(min(chapter.startSeconds + chapter.durationSeconds, max(duration - 1, 0)))
            }
            .accessibilityHidden(true)
    }
}

/// Runs an action once, when the playhead first passes a time.
struct TimeTrigger: View {
    var time: PlaybackTime
    let at: Double
    let action: () -> Void
    @State private var fired = false

    var body: some View {
        let reached = time.currentTime >= at
        Color.clear.frame(width: 0, height: 0)
            .onChange(of: reached) { _, now in
                guard now, !fired else { return }
                fired = true
                action()
            }
            .accessibilityHidden(true)
    }
}

/// "Skip Intro" from where you skipped in an earlier episode, for files without chapters.
struct LearnedSkipButton: View {
    var time: PlaybackTime
    let start: Double
    let end: Double
    let skip: (Double) -> Void

    var body: some View {
        let now = time.currentTime
        // Openings drift by a few seconds between episodes; offer it a little early and late.
        if now >= max(0, start - 15), now < end - 5 {
            Button { skip(end) } label: {
                Label("Skip Intro", systemImage: "forward.end.fill").font(.headline).padding(.horizontal, 6)
            }
            .buttonStyle(.glass)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }
}
