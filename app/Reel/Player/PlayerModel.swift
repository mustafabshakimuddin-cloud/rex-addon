import AVFoundation
import Combine
import MediaPlayer
import AetherEngine

/// One AetherEngine for the app's lifetime, as its author requires: hosts call `load(url:)` for each
/// title against the same engine instead of rebuilding the audio session and display criteria.
@MainActor
enum EngineHost {
    static let engine: AetherEngine? = {
        guard let engine = try? AetherEngine() else { return nil }
        // We draw our own transport, so the engine publishes the lock-screen / Control Center card
        // and answers its play, pause and skip commands. Read at host creation: set before load().
        engine.ownsVideoNowPlayingSession = true
        engine.ownsVideoNowPlayingCommands = true
        return engine
    }()
}

/// Mirrors the engine's published state for the player UI and drives a playback session.
@MainActor
final class PlayerModel: ObservableObject {
    let engine: AetherEngine?

    @Published private(set) var state: PlaybackState = .idle
    @Published private(set) var phase: PlaybackPhase = .idle
    @Published private(set) var duration: Double = 0
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var sourceTime: Double = 0
    @Published private(set) var buffered: Double = 0
    @Published private(set) var audioTracks: [TrackInfo] = []
    @Published private(set) var subtitleTracks: [TrackInfo] = []
    @Published private(set) var activeAudio: Int?
    @Published private(set) var activeSubtitle: Int?
    @Published private(set) var cues: [SubtitleCue] = []
    @Published private(set) var videoFormat: VideoFormat = .sdr
    @Published private(set) var hasFirstFrame = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var rate: Float = 1
    @Published var fillsScreen = false {
        didSet { engine?.videoGravity = fillsScreen ? .resizeAspectFill : .resizeAspect }
    }

    let pip = PictureInPicture()
    private var bag = Set<AnyCancellable>()
    private var started = false
    private var lastSaved: Double = -100
    private var onProgress: ((Double, Double) -> Void)?

    init() {
        engine = EngineHost.engine
        guard let engine else {
            errorMessage = "The video engine couldn't start on this device."
            return
        }
        engine.$state.sink { [weak self] value in self?.handle(state: value) }.store(in: &bag)
        engine.$playbackPhase.sink { [weak self] in self?.phase = $0 }.store(in: &bag)
        engine.$duration.sink { [weak self] in self?.duration = $0 }.store(in: &bag)
        engine.$audioTracks.sink { [weak self] in self?.audioTracks = $0 }.store(in: &bag)
        engine.$subtitleTracks.sink { [weak self] in self?.subtitleTracks = $0 }.store(in: &bag)
        engine.$activeAudioTrackIndex.sink { [weak self] in self?.activeAudio = $0 }.store(in: &bag)
        engine.$activeSubtitleTrackIndex.sink { [weak self] in self?.activeSubtitle = $0 }.store(in: &bag)
        engine.$subtitleCues.sink { [weak self] in self?.cues = $0 }.store(in: &bag)
        engine.$videoFormat.sink { [weak self] in self?.videoFormat = $0 }.store(in: &bag)
        engine.$hasFirstFrameReadyForDisplay.sink { [weak self] in self?.hasFirstFrame = $0 }.store(in: &bag)
        engine.clock.$sourceTime.sink { [weak self] in self?.sourceTime = $0 }.store(in: &bag)
        engine.clock.$bufferedPosition.sink { [weak self] in self?.buffered = $0 }.store(in: &bag)
        engine.clock.$currentTime.sink { [weak self] time in
            guard let self else { return }
            self.currentTime = time
            self.saveProgress(force: false)
        }.store(in: &bag)
        // A new AVPlayer (every load and reroute) means a new layer to build PiP around.
        engine.$currentAVPlayer.sink { [weak self] _ in
            guard let self, let engine = self.engine else { return }
            self.pip.attach(layer: engine.nativePlayerLayer, engine: engine)
        }.store(in: &bag)
    }

    func start(url: URL, title: String, subtitle: String?, startAt: Double?,
               audioLanguages: [String], subtitleLanguages: [String],
               onProgress: @escaping (Double, Double) -> Void) {
        guard !started, let engine else { return }
        started = true
        self.onProgress = onProgress
        engine.videoGravity = .resizeAspect

        var options = LoadOptions()
        options.preferredAudioLanguages = audioLanguages
        options.preferredSubtitleLanguages = subtitleLanguages
        var info: [String: Any] = [MPMediaItemPropertyTitle: title]
        if let subtitle { info[MPMediaItemPropertyArtist] = subtitle }
        engine.setNowPlayingInfo(info)

        Task {
            // We mount the engine's layer ourselves rather than AVPlayerViewController, so we
            // activate the session the engine declared (category .playback, multichannel).
            try? AVAudioSession.sharedInstance().setActive(true)
            do {
                _ = try await engine.load(url: url, startPosition: startAt, options: options)
            } catch is CancellationError {
                // A newer load replaced this one; not a failure.
            } catch {
                errorMessage = Self.message(for: error)
            }
        }
    }

    func stop() {
        saveProgress(force: true)
        pip.stop()
        engine?.stop()
    }

    // MARK: Transport

    var isPlaying: Bool { state == .playing }
    var isBusy: Bool {
        switch phase {
        case .loading, .seeking, .rebuffering, .stalled: return true
        default: return !hasFirstFrame && errorMessage == nil
        }
    }

    func togglePlay() { engine?.togglePlayPause() }

    func seek(to seconds: Double) {
        guard let engine, duration > 0 else { return }
        let target = min(max(0, seconds), max(0, duration - 1))
        currentTime = target
        Task { await engine.seek(to: target) }
    }

    func skip(_ seconds: Double) { seek(to: currentTime + seconds) }

    func setRate(_ value: Float) {
        guard let engine else { return }
        let clamped = min(value, engine.maxSupportedRate)
        engine.setRate(clamped)
        rate = clamped
    }

    func selectAudio(_ track: TrackInfo) { engine?.selectAudioTrack(index: track.id) }

    func selectSubtitle(_ track: TrackInfo?) {
        guard let engine else { return }
        if let track { engine.selectSubtitleTrack(index: track.id) } else { engine.clearSubtitle() }
    }

    /// The cues to show now. Cue times are on the source axis, so compare with `sourceTime`.
    var visibleCues: [SubtitleCue] {
        cues.filter { sourceTime >= $0.startTime && sourceTime <= $0.endTime }
    }

    // MARK: State

    private func handle(state value: PlaybackState) {
        state = value
        switch value {
        case let .error(message):
            errorMessage = engine?.errorInfo.map { "\(message) (\($0.kind))" } ?? message
        case .ended:
            saveProgress(force: true)
        default:
            break
        }
    }

    private func saveProgress(force: Bool) {
        guard duration > 0, currentTime.isFinite else { return }
        if force || abs(currentTime - lastSaved) >= 10 {
            lastSaved = currentTime
            onProgress?(currentTime, duration)
        }
    }

    private static func message(for error: Error) -> String {
        let text = (error as NSError).localizedDescription
        return text.isEmpty ? "This stream couldn't be opened. Try another source." : text
    }
}

/// Picture in Picture around the engine's own AVPlayerLayer (the native route). The engine keeps
/// the pipeline alive in the background while `pictureInPictureActive` is set.
@MainActor
final class PictureInPicture: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
    @Published private(set) var isPossible = false
    @Published private(set) var isActive = false
    private var controller: AVPictureInPictureController?
    private weak var engine: AetherEngine?
    private var possibleObservation: AnyCancellable?

    func attach(layer: AVPlayerLayer?, engine: AetherEngine) {
        self.engine = engine
        guard let layer, AVPictureInPictureController.isPictureInPictureSupported() else {
            controller = nil
            possibleObservation = nil
            isPossible = false
            return
        }
        if controller?.playerLayer === layer { return }
        let pip = AVPictureInPictureController(playerLayer: layer)
        pip?.delegate = self
        pip?.canStartPictureInPictureAutomaticallyFromInline = true
        controller = pip
        possibleObservation = pip?.publisher(for: \.isPictureInPicturePossible)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.isPossible = $0 }
    }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive { controller.stopPictureInPicture() } else { controller.startPictureInPicture() }
    }

    func stop() {
        controller?.stopPictureInPicture()
    }

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            self.engine?.pictureInPictureActive = true
            self.isActive = true
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            self.engine?.pictureInPictureActive = false
            self.isActive = false
        }
    }
}
