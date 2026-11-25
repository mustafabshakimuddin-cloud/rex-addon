import AVFoundation
import CoreGraphics
import AVKit
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

/// The position the scrubber shows, kept apart from PlayerModel: the engine's clock ticks ten
/// times a second, and only the scrubber and its time labels should redraw on a tick.
@MainActor
final class PlaybackTime: ObservableObject {
    @Published fileprivate(set) var currentTime: Double = 0
    /// Published in whole-second steps: the buffered bar is a few points wide per minute of film.
    @Published fileprivate(set) var buffered: Double = 0
}

/// The subtitle cues on screen now. The engine republishes its whole cue list on every subtitle
/// drain tick (twice a second) and the source clock ten times a second; this turns both into one
/// publication each time the visible set actually changes, which is a few times a minute.
@MainActor
final class SubtitleFeed: ObservableObject {
    @Published private(set) var visible: [SubtitleCue] = []
    private var cues: [SubtitleCue] = []
    private var now: Double = 0
    /// Positive shows subtitles later, negative earlier.
    private(set) var delay: Double = 0

    fileprivate func update(delay: Double) {
        self.delay = delay
        refresh()
    }

    fileprivate func update(cues: [SubtitleCue]) {
        self.cues = cues
        refresh()
    }

    fileprivate func update(time: Double) {
        now = time
        refresh()
    }

    private func refresh() {
        let at = now - delay
        let next = cues.isEmpty ? [] : cues.filter { at >= $0.startTime && at <= $0.endTime }
        guard next.count != visible.count
            || zip(next, visible).contains(where: { $0.id != $1.id || $0.startTime != $1.startTime || $0.endTime != $1.endTime })
        else { return }
        visible = next
    }
}

/// Mirrors the engine's published state for the player UI and drives a playback session.
@MainActor
final class PlayerModel: ObservableObject {
    let engine: AetherEngine?

    @Published private(set) var state: PlaybackState = .idle
    @Published private(set) var phase: PlaybackPhase = .idle
    @Published private(set) var duration: Double = 0
    let time = PlaybackTime()
    let subtitles = SubtitleFeed()
    var currentTime: Double { time.currentTime }
    @Published private(set) var audioTracks: [TrackInfo] = []
    @Published private(set) var subtitleTracks: [TrackInfo] = []
    @Published private(set) var activeAudio: Int?
    @Published private(set) var activeSubtitle: Int?
    @Published private(set) var videoFormat: VideoFormat = .sdr
    @Published private(set) var hasFirstFrame = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var rate: Float = 1
    @Published private(set) var chapters: [ChapterInfo] = []
    @Published private(set) var subtitleDelay: Double = 0
    @Published private(set) var onlineSubtitles: [OnlineSubtitles.Result] = []
    @Published private(set) var searchingSubtitles = false
    /// Raised each time the engine reports a rebuffer, for the source memory.
    @Published private(set) var stallCount = 0
    @Published var fillsScreen = false {
        didSet { engine?.videoGravity = fillsScreen ? .resizeAspectFill : .resizeAspect }
    }
    /// When playback pauses by itself: after a set time, or at the end of this episode.
    @Published var sleepTimer: SleepTimer? {
        didSet { sleepFired = false }
    }
    /// Raised when the sleep timer paused playback.
    @Published private(set) var sleepFired = false
    /// Being held for double speed.
    @Published private(set) var boosted = false

    enum SleepTimer: Equatable {
        case at(Date)
        case endOfEpisode

        var title: String {
            switch self {
            case let .at(date): return "Pauses at \(date.formatted(date: .omitted, time: .shortened))"
            case .endOfEpisode: return "Pauses at the end"
            }
        }
    }

    let pip = PictureInPicture()
    private var bag = Set<AnyCancellable>()
    private var started = false
    private var restoring = false
    private var lastSaved: Double = -100
    private var onProgress: ((Double, Double) -> Void)?
    private var loadOptions = LoadOptions()
    private var rateBeforeBoost: Float = 1

    init() {
        engine = EngineHost.engine
        guard let engine else {
            errorMessage = "The video engine couldn't start on this device."
            return
        }
        // Every assignment to a @Published property redraws the whole player, glass and all, even
        // when the value is the one it already held, so nothing reaches it unchanged.
        engine.$state.removeDuplicates().sink { [weak self] value in self?.handle(state: value) }.store(in: &bag)
        engine.$playbackPhase.removeDuplicates().sink { [weak self] in self?.phase = $0 }.store(in: &bag)
        engine.$duration.removeDuplicates().sink { [weak self] in self?.duration = $0 }.store(in: &bag)
        engine.$audioTracks.removeDuplicates().sink { [weak self] in self?.audioTracks = $0 }.store(in: &bag)
        engine.$subtitleTracks.removeDuplicates().sink { [weak self] in self?.subtitleTracks = $0 }.store(in: &bag)
        engine.$activeAudioTrackIndex.removeDuplicates().sink { [weak self] in self?.activeAudio = $0 }.store(in: &bag)
        engine.$activeSubtitleTrackIndex.removeDuplicates().sink { [weak self] in self?.activeSubtitle = $0 }.store(in: &bag)
        engine.$videoFormat.removeDuplicates().sink { [weak self] in self?.videoFormat = $0 }.store(in: &bag)
        engine.$hasFirstFrameReadyForDisplay.removeDuplicates().sink { [weak self] in self?.hasFirstFrame = $0 }.store(in: &bag)
        engine.$mediaChapters.removeDuplicates().sink { [weak self] in self?.chapters = $0 }.store(in: &bag)
        engine.$playbackPhase.removeDuplicates().sink { [weak self] phase in
            guard let self, self.hasFirstFrame, case .rebuffering = phase else { return }
            self.stallCount += 1
        }.store(in: &bag)
        // Cues and the source clock go to the subtitle feed only, never to the player.
        engine.$subtitleCues.sink { [weak self] in self?.subtitles.update(cues: $0) }.store(in: &bag)
        engine.clock.$sourceTime.removeDuplicates().sink { [weak self] in self?.subtitles.update(time: $0) }.store(in: &bag)
        engine.clock.$bufferedPosition
            .map { $0.isFinite ? $0.rounded(.down) : 0 }
            .removeDuplicates()
            .sink { [weak self] in self?.time.buffered = $0 }.store(in: &bag)
        engine.clock.$currentTime.removeDuplicates().sink { [weak self] value in
            guard let self else { return }
            self.time.currentTime = value
            self.saveProgress(force: false)
            self.checkSleepTimer()
        }.store(in: &bag)
        // The PiP button reads pip.isPossible, which turns true a moment after the layer is ready;
        // pass its changes through so the player view redraws when it does.
        pip.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        // A new AVPlayer (every load and reroute) means a new layer to build PiP around.
        engine.$currentAVPlayer.sink { [weak self] _ in
            guard let self, let engine = self.engine else { return }
            self.pip.attach(layer: engine.nativePlayerLayer, engine: engine)
        }.store(in: &bag)
    }

    func start(url: URL, title: String, subtitle: String?, startAt: Double?,
               audioLanguages: [String], subtitleLanguages: [String], artwork: URL? = nil,
               localSubtitles: [URL] = [],
               onProgress: @escaping (Double, Double) -> Void) {
        guard !started, let engine else { return }
        started = true
        self.onProgress = onProgress
        engine.videoGravity = fillsScreen ? .resizeAspectFill : .resizeAspect

        var options = LoadOptions()
        options.preferredAudioLanguages = audioLanguages
        options.preferredSubtitleLanguages = subtitleLanguages
        loadOptions = options
        var info: [String: Any] = [MPMediaItemPropertyTitle: title]
        if let subtitle { info[MPMediaItemPropertyArtist] = subtitle }
        engine.setNowPlayingInfo(info)
        // The lock screen and Control Center show the title's picture once it has loaded.
        if let artwork {
            Task {
                guard let image = await ImageLoader.shared.image(for: artwork, maxPixelSize: 600) else { return }
                info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                engine.setNowPlayingInfo(info)
            }
        }

        Task {
            // We mount the engine's layer ourselves rather than AVPlayerViewController, so we
            // activate the session the engine declared (category .playback, multichannel).
            try? AVAudioSession.sharedInstance().setActive(true)
            do {
                _ = try await engine.load(url: url, startPosition: startAt, options: options)
                for file in localSubtitles {
                    let language = file.deletingPathExtension().pathExtension
                    let name = "\(Languages.name(for: language)) · Saved"
                    _ = engine.addExternalSubtitleTrack(ExternalSubtitleTrack(url: file, name: name, language: language))
                }
            } catch is CancellationError {
                // A newer load replaced this one; not a failure.
            } catch {
                errorMessage = Self.message(for: error)
            }
        }
    }

    /// Opens a fresh address for the same file at the same place, after a link expired.
    func reload(url: URL, at position: Double?) {
        guard let engine else { return }
        errorMessage = nil
        let at = position.flatMap { $0 > 1 ? $0 : nil }
        Task {
            do {
                _ = try await engine.load(url: url, startPosition: at, options: loadOptions)
            } catch is CancellationError {
            } catch {
                errorMessage = Self.message(for: error)
            }
        }
    }

    // MARK: Sleep timer

    private func checkSleepTimer() {
        guard case let .at(date)? = sleepTimer, !sleepFired, Date() >= date else { return }
        sleepFired = true
        sleepTimer = nil
        if isPlaying { engine?.togglePlayPause() }
        sleepFired = true
    }

    /// The end-of-episode timer: playback stops instead of going on to the next one.
    var stopsAtEnd: Bool { sleepTimer == .endOfEpisode }

    // MARK: Hold for speed

    func beginBoost() {
        guard !boosted, isPlaying else { return }
        rateBeforeBoost = rate
        boosted = true
        setRate(2)
    }

    func endBoost() {
        guard boosted else { return }
        boosted = false
        setRate(rateBeforeBoost)
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

    func togglePlay() {
        guard let engine else { return }
        // Play after the stream was released in the background reopens it playing.
        if engine.needsForegroundVideoRestore {
            restore(playing: true)
            return
        }
        engine.togglePlayPause()
    }

    // MARK: Background

    /// A paused video left in the background for more than 15 s is released by the engine to save
    /// memory, and the engine leaves reopening it to the app. Without this the player came back to
    /// a spinner over a stream that no longer existed. Called when the scene becomes active again.
    func restoreAfterBackground() {
        guard engine?.needsForegroundVideoRestore == true else { return }
        restore(playing: false)
    }

    private func restore(playing: Bool) {
        guard let engine, !restoring else { return }
        restoring = true
        Task {
            defer { restoring = false }
            do {
                // The one rebuild where `autoplay` is applied: there is no transport left to keep,
                // so the app decides. It was paused when the app left, so it comes back paused,
                // on the same frame, unless Play was what brought it back.
                try await engine.reloadAtCurrentPosition { $0.autoplay = playing }
            } catch is CancellationError {
            } catch {
                errorMessage = Self.message(for: error)
            }
        }
    }


    func seek(to seconds: Double) {
        guard let engine, duration > 0 else { return }
        let target = min(max(0, seconds), max(0, duration - 1))
        time.currentTime = target
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

    // MARK: Subtitles

    func setSubtitleDelay(_ seconds: Double) {
        let value = (seconds * 4).rounded() / 4
        subtitleDelay = value
        subtitles.update(delay: value)
        engine?.setSoftwareSubtitleDelay(value)
    }

    /// Looks the title up on OpenSubtitles. With `autoAdd`, the first result in a preferred
    /// language becomes a track, which the engine then selects by the same language preference.
    func searchOnlineSubtitles(kind: MediaKind, videoID: String, filename: String?, size: Double?, autoAdd languages: [String] = []) {
        guard !searchingSubtitles else { return }
        searchingSubtitles = true
        Task {
            defer { searchingSubtitles = false }
            let results = (try? await OnlineSubtitles.search(kind: kind, videoID: videoID, filename: filename, size: size)) ?? []
            onlineSubtitles = results
            guard !languages.isEmpty else { return }
            let hasOwn = subtitleTracks.contains { track in
                guard let language = track.language?.lowercased() else { return false }
                return languages.contains(language)
            }
            if !hasOwn, let pick = results.first(where: { languages.contains($0.language) }) {
                addOnlineSubtitle(pick, select: false)
            }
        }
    }

    func addOnlineSubtitle(_ result: OnlineSubtitles.Result, name: String? = nil, select: Bool = true) {
        guard let engine else { return }
        let name = name ?? "\(Languages.name(for: result.language)) · OpenSubtitles"
        if let existing = subtitleTracks.first(where: { $0.isExternal && $0.name == name }) {
            if select { engine.selectSubtitleTrack(index: existing.id) }
            return
        }
        let info = engine.addExternalSubtitleTrack(ExternalSubtitleTrack(url: result.url, name: name, language: result.language))
        if select { engine.selectSubtitleTrack(index: info.id) }
    }

    // MARK: Previews

    func thumbnail(at seconds: Double) async -> CGImage? {
        await engine?.scrubThumbnail(atSeconds: seconds, maxWidth: 320)
    }

    func selectSubtitle(_ track: TrackInfo?) {
        guard let engine else { return }
        if let track { engine.selectSubtitleTrack(index: track.id) } else { engine.clearSubtitle() }
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
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                guard let self, self.isPossible != value else { return }
                self.isPossible = value
            }
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
