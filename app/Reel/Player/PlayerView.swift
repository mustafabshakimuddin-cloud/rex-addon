import SwiftUI
import AVKit
import AetherEngine

struct PlayerView: View {
    let session: PlayerSession
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var playback: PlaybackCenter
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = PlayerModel()
    @State private var controlsVisible = true
    @State private var panel: OptionsPanel.Tab?
    @State private var scrubbing: Double?
    @State private var hideTask: Task<Void, Never>?
    @State private var width: CGFloat = 400

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let engine = model.engine {
                AetherPlayerSurface(engine: engine)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            if !model.hasFirstFrame && model.errorMessage == nil {
                StartupCover(session: session)
                    .transition(.opacity)
            }

            SubtitleOverlay(model: model, bottomInset: controlsVisible ? 150 : 36)

            // Owns the taps above the video: one shows or hides the controls, two toggle fill.
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture(count: 2) { model.fillsScreen.toggle() }
                .onTapGesture { toggleControls() }

            if model.isBusy && model.hasFirstFrame {
                ProgressView().controlSize(.large).tint(.white).allowsHitTesting(false)
            }

            if controlsVisible || model.errorMessage != nil {
                controls.transition(.opacity)
            }

            if let tab = panel {
                Color.black.opacity(0.35).ignoresSafeArea()
                    .onTapGesture { closePanel() }
                    .transition(.opacity)
                OptionsPanel(model: model, tab: tab, wide: width >= 640) { closePanel() }
                    .transition(.move(edge: width >= 640 ? .trailing : .bottom).combined(with: .opacity))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .statusBarHidden(!controlsVisible)
        .persistentSystemOverlays(controlsVisible ? .automatic : .hidden)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.22), value: controlsVisible)
        .animation(.spring(duration: 0.35), value: panel)
        .animation(.easeOut(duration: 0.3), value: model.hasFirstFrame)
        .onAppear(perform: start)
        .onDisappear {
            hideTask?.cancel()
            model.stop()
            library.saveNow()
        }
        .onChange(of: model.isPlaying) { _, playing in if playing { scheduleHide() } }
        .onChange(of: model.state) { _, state in if state == .ended { dismiss() } }
    }

    private func start() {
        let target = session.target
        model.start(
            url: session.url,
            title: target.item.name,
            subtitle: target.episode.map { "\($0.code) · \($0.title)" },
            startAt: session.startAt,
            audioLanguages: Languages.codes(for: settings.preferredAudioLanguage),
            subtitleLanguages: settings.autoplaySubtitles ? Languages.codes(for: settings.preferredSubtitleLanguage) : [],
            onProgress: { [weak lib = library] position, duration in
                lib?.record(target, position: position, duration: duration)
            }
        )
        scheduleHide()
    }

    // MARK: Controls

    private var controls: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.7), .clear, .clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                if let error = model.errorMessage {
                    errorCard(error)
                } else {
                    transport
                }
                Spacer(minLength: 0)
                bottomBar
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 14) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).frame(width: 22, height: 22)
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Close player")

            VStack(alignment: .leading, spacing: 3) {
                Text(session.target.item.name).font(.headline).lineLimit(1)
                if let episode = session.target.episode {
                    Text("\(episode.code) · \(episode.title)").font(.subheadline).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                }
                infoChips
            }
            Spacer(minLength: 8)
            if model.pip.isPossible {
                Button { model.pip.toggle() } label: {
                    Image(systemName: "pip.enter").font(.headline).frame(width: 22, height: 22)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Picture in Picture")
            }
            AirPlayButton()
                .frame(width: 44, height: 44)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("AirPlay")
        }
    }

    private var infoChips: some View {
        HStack(spacing: 6) {
            PlayerChip(text: session.source.quality)
            if let format = Self.formatLabel(model.videoFormat) { PlayerChip(text: format, highlighted: true) }
            if let audio = activeAudioTrack {
                if audio.isAtmos { PlayerChip(text: "Dolby Atmos", highlighted: true) }
                else if let layout = TrackLabel.channels(audio.channels), audio.channels > 2 { PlayerChip(text: layout) }
            }
            if let size = session.source.size { PlayerChip(text: size) }
        }
        .padding(.top, 4)
    }

    private var transport: some View {
        HStack(spacing: 46) {
            Button { model.skip(-10); scheduleHide() } label: {
                Image(systemName: "gobackward.10").font(.system(size: 30, weight: .semibold))
            }
            Button { model.togglePlay(); scheduleHide() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 38, weight: .bold))
                    .frame(width: 86, height: 86)
                    .contentTransition(.symbolEffect(.replace))
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            Button { model.skip(10); scheduleHide() } label: {
                Image(systemName: "goforward.10").font(.system(size: 30, weight: .semibold))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            Scrubber(
                value: scrubbing ?? model.currentTime,
                buffered: model.buffered,
                duration: model.duration,
                onChange: { scrubbing = $0; hideTask?.cancel() },
                onCommit: { value in
                    model.seek(to: value)
                    scrubbing = nil
                    scheduleHide()
                }
            )
            HStack {
                Text(Self.clock(scrubbing ?? model.currentTime))
                Spacer()
                Text("-" + Self.clock(max(0, model.duration - (scrubbing ?? model.currentTime))))
            }
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))

            HStack(spacing: 10) {
                barButton("Sources", "list.bullet.rectangle") { playback.switchSource(for: session.target) }
                barButton("Audio & Subtitles", "waveform.and.captions") { openPanel(.audio) }
                barButton(Self.rateLabel(model.rate), "gauge.with.dots.needle.67percent") { openPanel(.speed) }
                Spacer(minLength: 0)
                Button {
                    model.fillsScreen.toggle()
                    scheduleHide()
                } label: {
                    Image(systemName: model.fillsScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.headline)
                }
                .buttonStyle(.glass)
                .accessibilityLabel(model.fillsScreen ? "Fit to screen" : "Fill screen")
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }

    private func barButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .labelStyle(AdaptiveLabelStyle(showsTitle: width >= 520))
        }
        .buttonStyle(.glass)
        .accessibilityLabel(title)
    }

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
            Text("This source couldn't be played").font(.headline)
            Text(message).font(.footnote).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Try Another Source") { playback.switchSource(for: session.target) }
                    .buttonStyle(.glassProminent)
                Button("Close") { dismiss() }.buttonStyle(.glass)
            }
        }
        .padding(24)
        .frame(maxWidth: 420)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }

    private var activeAudioTrack: TrackInfo? {
        model.audioTracks.first { $0.id == model.activeAudio } ?? model.audioTracks.first { $0.isDefault }
    }

    // MARK: Behaviour

    private func toggleControls() {
        if panel != nil { closePanel(); return }
        controlsVisible.toggle()
        if controlsVisible { scheduleHide() }
    }

    private func openPanel(_ tab: OptionsPanel.Tab) {
        hideTask?.cancel()
        panel = tab
    }

    private func closePanel() {
        panel = nil
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        controlsVisible = true
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, model.isPlaying, scrubbing == nil, panel == nil else { return }
            controlsVisible = false
        }
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.isFinite ? max(0, seconds) : 0)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func rateLabel(_ rate: Float) -> String {
        rate == 1 ? "Speed" : (rate.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(rate))×" : "\(rate)×")
    }

    static func formatLabel(_ format: VideoFormat) -> String? {
        switch format {
        case .dolbyVision: return "Dolby Vision"
        case .hdr10Plus: return "HDR10+"
        case .hdr10: return "HDR10"
        case .hlg: return "HLG"
        default: return nil
        }
    }
}

// MARK: - Pieces

/// Shown until the engine has a first picture: the title's art, blurred, with a spinner.
private struct StartupCover: View {
    let session: PlayerSession

    var body: some View {
        ZStack {
            RemoteImage(url: session.target.episode?.thumbnail ?? session.target.item.background)
                .blur(radius: 30)
                .overlay(Color.black.opacity(0.55))
                .ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView().controlSize(.large).tint(.white)
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
                Circle()
                    .fill(.white)
                    .frame(width: dragging ? 22 : 14, height: dragging ? 22 : 14)
                    .shadow(radius: 3)
                    .offset(x: width * progress - (dragging ? 11 : 7))
            }
            .frame(height: dragging ? 8 : 5)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
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
            .animation(.snappy(duration: 0.2), value: dragging)
        }
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(PlayerView.clock(value))
        .accessibilityAdjustableAction { direction in
            onCommit(value + (direction == .increment ? 30 : -30))
        }
    }
}

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
