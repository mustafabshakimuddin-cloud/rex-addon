import SwiftUI
import UIKit

/// VLC draws into a plain UIView; SwiftUI only hosts it.
struct VLCVideoSurface: UIViewRepresentable {
    let controller: PlayerController

    func makeUIView(context: Context) -> SurfaceView {
        let view = SurfaceView()
        view.backgroundColor = .black
        // VLC draws through its own layers and would swallow touches; taps go to SwiftUI instead.
        view.isUserInteractionEnabled = false
        view.onLayout = { [weak player = controller] in Task { @MainActor in player?.applyScale() } }
        controller.attach(view)
        return view
    }

    func updateUIView(_ uiView: SurfaceView, context: Context) {}

    /// Re-fits the picture whenever the window changes size: rotation, iPhone Duo fold/unfold, iPad windows.
    final class SurfaceView: UIView {
        var onLayout: (() -> Void)?
        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?()
        }
    }
}

struct PlayerView: View {
    let session: PlayerSession
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var playback: PlaybackCenter
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = PlayerController()
    @State private var controlsVisible = true
    @State private var scrubbing: Double?
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VLCVideoSurface(controller: controller)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // A transparent layer above the video owns the taps: one tap shows or hides the
            // controls, two toggle fill. It sits under the controls, so their buttons still work.
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture(count: 2) { controller.fillsScreen.toggle() }
                .onTapGesture { toggleControls() }

            if controller.isBuffering && controller.errorMessage == nil {
                ProgressView().controlSize(.large).tint(.white).allowsHitTesting(false)
            }

            if controlsVisible || controller.errorMessage != nil {
                controls.transition(.opacity)
            }
        }
        .statusBarHidden(!controlsVisible)
        .persistentSystemOverlays(controlsVisible ? .automatic : .hidden)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        .onAppear(perform: start)
        .onDisappear {
            hideTask?.cancel()
            controller.stop()
            library.saveNow()
        }
        .onChange(of: controller.isPlaying) { _, playing in if playing { scheduleHide() } }
        .onChange(of: controller.hasEnded) { _, ended in if ended { dismiss() } }
    }

    private func start() {
        let target = session.target
        controller.onProgress = { [weak lib = library] position, duration in
            lib?.record(target, position: position, duration: duration)
        }
        let subtitle = settings.autoplaySubtitles
            ? SettingsView.languages.first { $0.0 == settings.preferredSubtitleLanguage }?.1
            : nil
        controller.start(url: session.url, startAt: session.startAt, preferredSubtitle: subtitle)
        scheduleHide()
    }

    // MARK: Controls

    private var controls: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.65), .clear, .clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer()
                if let error = controller.errorMessage {
                    VStack(spacing: 14) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
                        Text(error).multilineTextAlignment(.center)
                        Button("Close") { dismiss() }.buttonStyle(.glassProminent)
                    }
                    .padding(24)
                    .glassEffect(.regular, in: .rect(cornerRadius: 28))
                } else {
                    transport
                }
                Spacer()
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

            VStack(alignment: .leading, spacing: 2) {
                Text(session.target.item.name).font(.headline).lineLimit(1)
                if let episode = session.target.episode {
                    Text("\(episode.code) · \(episode.title)").font(.subheadline).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                }
                Text([session.source.quality, session.source.size].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
            Spacer()
        }
    }

    private var transport: some View {
        HStack(spacing: 44) {
            Button { controller.skip(-10); scheduleHide() } label: {
                Image(systemName: "gobackward.10").font(.system(size: 30, weight: .semibold))
            }
            Button { controller.togglePlay(); scheduleHide() } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 38, weight: .bold))
                    .frame(width: 84, height: 84)
                    .contentTransition(.symbolEffect(.replace))
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            Button { controller.skip(10); scheduleHide() } label: {
                Image(systemName: "goforward.10").font(.system(size: 30, weight: .semibold))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text(Self.clock(scrubbing ?? controller.position)).monospacedDigit()
                Slider(
                    value: Binding(get: { scrubbing ?? controller.position }, set: { scrubbing = $0 }),
                    in: 0...max(controller.duration, 1),
                    onEditingChanged: { editing in
                        if editing {
                            hideTask?.cancel()
                        } else if let value = scrubbing {
                            controller.seek(to: value)
                            scrubbing = nil
                            scheduleHide()
                        }
                    }
                )
                .tint(Theme.accent)
                Text("-" + Self.clock(max(0, controller.duration - (scrubbing ?? controller.position)))).monospacedDigit()
            }
            .font(.caption.weight(.semibold))

            HStack(spacing: 12) {
                Button {
                    playback.switchSource(for: session.target)
                } label: {
                    Label("Sources", systemImage: "list.bullet.rectangle").font(.headline)
                }
                .buttonStyle(.glass)
                Spacer()
                trackMenu(title: "Audio", systemImage: "waveform", tracks: controller.audioTracks, current: controller.currentAudio, select: controller.selectAudio)
                trackMenu(title: "Subtitles", systemImage: "captions.bubble", tracks: controller.subtitleTracks, current: controller.currentSubtitle, select: controller.selectSubtitle)
                Button {
                    controller.fillsScreen.toggle()
                    scheduleHide()
                } label: {
                    Image(systemName: controller.fillsScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.headline)
                }
                .buttonStyle(.glass)
                .accessibilityLabel(controller.fillsScreen ? "Fit to screen" : "Fill screen")
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
    }

    private func trackMenu(title: String, systemImage: String, tracks: [PlayerController.Track], current: Int32, select: @escaping (Int32) -> Void) -> some View {
        Menu {
            Picker(title, selection: Binding(get: { current }, set: { select($0); scheduleHide() })) {
                ForEach(tracks) { Text($0.name).tag($0.id) }
            }
        } label: {
            Label(title, systemImage: systemImage).font(.headline).labelStyle(.iconOnly)
        }
        .buttonStyle(.glass)
        .disabled(tracks.count <= 1)
        .accessibilityLabel(title)
    }

    private func toggleControls() {
        controlsVisible.toggle()
        if controlsVisible { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        controlsVisible = true
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled, controller.isPlaying, scrubbing == nil else { return }
            controlsVisible = false
        }
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.isFinite ? seconds : 0)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
