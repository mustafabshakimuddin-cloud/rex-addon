import UIKit
import Combine
import MobileVLCKit

/// Wraps VLCMediaPlayer. State is polled four times a second instead of using VLCKit's delegate:
/// its Objective-C delegate methods are optional, so a signature that differs from the headers
/// in optionality compiles fine and is then silently never called. Polling cannot fail that way.
@MainActor
final class PlayerController: ObservableObject {
    struct Track: Identifiable, Hashable {
        let id: Int32
        let name: String
    }

    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = true
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var audioTracks: [Track] = []
    @Published private(set) var subtitleTracks: [Track] = []
    @Published private(set) var currentAudio: Int32 = -1
    @Published private(set) var currentSubtitle: Int32 = -1
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasEnded = false
    @Published var fillsScreen = false { didSet { applyScale() } }

    let player = VLCMediaPlayer()
    private weak var drawable: UIView?
    private var timer: Timer?
    private var started = false
    private var preferredSubtitle: String?
    private var appliedSubtitlePreference = false
    private var lastProgress: Double = -1
    var onProgress: ((Double, Double) -> Void)?

    func attach(_ view: UIView) {
        drawable = view
        player.drawable = view
    }

    func start(url: URL, startAt: Double?, preferredSubtitle: String?) {
        guard !started else { return }
        started = true
        self.preferredSubtitle = preferredSubtitle
        let media = VLCMedia(url: url)
        media.addOption(":network-caching=3000")
        media.addOption(":http-reconnect")
        if let startAt, startAt > 0 { media.addOption(":start-time=\(Int(startAt))") }
        player.media = media
        if preferredSubtitle == nil { player.currentVideoSubTitleIndex = -1 }
        player.play()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        report(force: true)
        timer?.invalidate()
        timer = nil
        player.stop()
    }

    func togglePlay() {
        if player.isPlaying { player.pause() } else { player.play() }
        poll()
    }

    func seek(to seconds: Double) {
        guard duration > 0 else { return }
        player.time = VLCTime(int: Int32(max(0, min(seconds, duration - 1)) * 1000))
        position = seconds
    }

    func skip(_ seconds: Int32) {
        if seconds >= 0 { player.jumpForward(seconds) } else { player.jumpBackward(-seconds) }
    }

    func selectAudio(_ id: Int32) {
        player.currentAudioTrackIndex = id
        currentAudio = id
    }

    func selectSubtitle(_ id: Int32) {
        player.currentVideoSubTitleIndex = id
        currentSubtitle = id
    }

    /// Fill crops the picture to the window; off letterboxes it (the default, and what the
    /// unfolded iPhone Duo's near-square display wants for 16:9 video).
    func applyScale() {
        guard let view = drawable else { return }
        let video = player.videoSize
        guard fillsScreen, video.width > 0, video.height > 0 else {
            player.scaleFactor = 0
            return
        }
        let pixels = CGSize(width: view.bounds.width * view.contentScaleFactor, height: view.bounds.height * view.contentScaleFactor)
        player.scaleFactor = Float(max(pixels.width / video.width, pixels.height / video.height))
    }

    private func poll() {
        let state = player.state
        isPlaying = player.isPlaying
        isBuffering = state == .opening || state == .buffering && !player.isPlaying
        if let length = player.media?.length.intValue, length > 0 { duration = Double(length) / 1000 }
        position = max(0, Double(player.time.intValue) / 1000)

        switch state {
        case .error:
            errorMessage = "This stream couldn't be played. Try another source."
        case .ended:
            hasEnded = true
            report(force: true)
        default:
            break
        }
        refreshTracks()
        report(force: false)
    }

    private func refreshTracks() {
        let audio = Self.tracks(names: player.audioTrackNames, indexes: player.audioTrackIndexes)
        if audio != audioTracks { audioTracks = audio }
        let subtitles = Self.tracks(names: player.videoSubTitlesNames, indexes: player.videoSubTitlesIndexes)
        if subtitles != subtitleTracks { subtitleTracks = subtitles }
        currentAudio = player.currentAudioTrackIndex
        currentSubtitle = player.currentVideoSubTitleIndex

        if !appliedSubtitlePreference, let preferred = preferredSubtitle?.lowercased(), subtitles.contains(where: { $0.id >= 0 }) {
            appliedSubtitlePreference = true
            if let match = subtitles.first(where: { $0.id >= 0 && $0.name.lowercased().contains(preferred) }) {
                selectSubtitle(match.id)
            }
        }
    }

    private static func tracks(names: [Any]?, indexes: [Any]?) -> [Track] {
        let names = (names ?? []).map { "\($0)" }
        let ids = (indexes ?? []).compactMap { ($0 as? NSNumber)?.int32Value }
        return zip(ids, names).map { Track(id: $0, name: $0 < 0 ? "Off" : $1) }
    }

    /// Hands progress to the library at most every ten seconds, and always on stop/end.
    private func report(force: Bool) {
        guard duration > 0 else { return }
        if force || abs(position - lastProgress) >= 10 {
            lastProgress = position
            onProgress?(position, duration)
        }
    }
}
