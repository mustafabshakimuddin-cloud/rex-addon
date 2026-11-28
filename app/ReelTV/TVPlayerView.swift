import SwiftUI
import AVKit
import AetherEngine

/// The player on Apple TV: the same engine, model and behaviour as on iPhone (resume, Trakt,
/// reconnecting an expired link, falling back to the next source, Up Next, Skip Intro, learned
/// intros, remembered audio and subtitle choices), driven by the Siri Remote.
///
/// - Select shows the controls; held, it plays at double speed. With Skip Intro or Up Next on
///   screen, Select takes it.
/// - Left and right skip 10 seconds; on the timeline they scrub, Select jumps there and Back
///   cancels.
/// - Down opens audio, subtitles and speed; up shows the controls.
/// - Play/Pause plays and pauses; Back closes whatever is open, then the player.
struct PlayerView: View {
    let session: PlayerSession
    @Environment(Library.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(PlaybackCenter.self) private var playback
    @Environment(TraktStore.self) private var trakt
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = PlayerModel()
    @State private var controlsVisible = true
    @State private var panel: OptionsPanel.Tab?
    @State private var scrubbing: Double?
    @State private var hideTask: Task<Void, Never>?
    @State private var nextEpisode: Episode?
    @State private var reportedStart = false
    @State private var handledFailure = false
    @State private var reconnecting = false
    @State private var reconnects = 0
    @State private var skipFlash: SkipFlash?
    @State private var boostTask: Task<Void, Never>?
    @State private var learnedIntro: ViewingChoice?
    @State private var preparedNext = false
    @State private var sentStop = false
    /// What Select does while the controls are hidden, reported by the skip and Up Next prompts.
    @State private var skipOffer: SkipOffer?
    @State private var upNextShowing = false
    @State private var upNextDismissed = false
    /// When the last scrub step was taken, to speed up a held or repeated swipe.
    @State private var lastScrubStep = Date.distantPast
    @State private var scrubStreak = 0
    @FocusState private var focus: Focus?

    enum Focus: Hashable { case catcher, timeline }
    struct SkipFlash: Equatable { let forward: Bool; let id = UUID() }
    struct SkipOffer: Equatable { let title: String; let to: Double }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            picture
            SubtitleOverlay(feed: model.subtitles, bottomInset: controlsVisible ? 260 : 60, appearance: settings.subtitleAppearance)
            catcher

            if let skipFlash {
                SkipFlashView(forward: skipFlash.forward)
                    .id(skipFlash.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: skipFlash.forward ? .trailing : .leading)
                    .padding(.horizontal, 120)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            if model.boosted { notice("2× speed", "forward.fill") }
            if model.sleepFired && !model.isPlaying { notice("Paused by the sleep timer", "moon.zzz.fill") }
            if model.isBusy && model.hasFirstFrame {
                ProgressView().largeControl().tint(.white).allowsHitTesting(false)
            }

            if controlsVisible || model.errorMessage != nil {
                controls.transition(.opacity)
            }
            cornerActions
                .padding(.bottom, controlsVisible ? 300 : 80)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            watchers
            optionsPanel
            fallbackNotice
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.22), value: controlsVisible)
        .animation(.spring(duration: 0.35), value: panel)
        .animation(.easeOut(duration: 0.3), value: model.hasFirstFrame)
        .onAppear(perform: start)
        .onDisappear(perform: finish)
        .task { await loadNextEpisode() }
        .onChange(of: model.isPlaying) { _, playing in
            if playing { scheduleHide() } else { showControls() }
            scrobble(playing ? .start : .pause)
        }
        .onChange(of: model.state) { _, state in if state == .ended { ended() } }
        .onChange(of: model.hasFirstFrame) { _, ready in if ready { started() } }
        .onChange(of: model.errorMessage) { _, message in if let message { failed(message) } }
        .onChange(of: model.stallCount) { _, _ in playback.playerStalled(session) }
        .onChange(of: settings.audioShaping) { _, shaping in model.setAudioShaping(shaping) }
        .onChange(of: focus) { _, _ in if controlsVisible { scheduleHide() } }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            model.restoreAfterBackground()
            showControls()
        }
    }

    // MARK: Layers

    private var picture: some View {
        ZStack {
            if let engine = model.engine {
                AetherPlayerSurface(engine: engine)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            if !model.hasFirstFrame && model.errorMessage == nil {
                StartupCover(session: session).transition(.opacity)
            }
        }
    }

    /// Holds focus while the controls are hidden and turns the remote's presses into actions.
    private var catcher: some View {
        Color.clear
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .focusable(!controlsVisible && panel == nil && model.errorMessage == nil)
            .focused($focus, equals: .catcher)
            .onTapGesture { select() }
            .onLongPressGesture(minimumDuration: 0.5) {
            } onPressingChanged: { pressing in
                boostTask?.cancel()
                if pressing {
                    boostTask = Task {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        if !Task.isCancelled { model.beginBoost() }
                    }
                } else {
                    model.endBoost()
                }
            }
            .onMoveCommand { direction in
                switch direction {
                case .left: skip(-10)
                case .right: skip(10)
                case .down: openPanel(.audio)
                default: showControls()
                }
            }
            .onPlayPauseCommand { model.togglePlay() }
            .onExitCommand {
                if upNextShowing && !upNextDismissed { upNextDismissed = true } else { dismiss() }
            }
    }

    /// Reports what Select should do while the controls are hidden: skip a chapter or an intro.
    @ViewBuilder private var watchers: some View {
        SkipWatcher(time: model.time, chapters: settings.showSkipButtons ? model.chapters : [], duration: model.duration,
                    skipsCredits: nextEpisode == nil, learned: learnedSkip) { skipOffer = $0 }
        if (settings.autoSkipIntro || settings.autoSkipRecap) && !model.chapters.isEmpty {
            AutoSkipper(time: model.time, chapters: model.chapters, duration: model.duration,
                        intro: settings.autoSkipIntro, recap: settings.autoSkipRecap) { model.seek(to: $0) }
        }
        if let nextEpisode, let startsAt = upNextStart, !preparedNext {
            TimeTrigger(time: model.time, at: max(0, startsAt - 90)) {
                preparedNext = true
                playback.prefetch(PlaybackTarget(item: session.target.item, episode: nextEpisode), settings: settings,
                                  immediately: true, prepare: settings.autoPlayNext)
            }
        }
        if nextEpisode != nil, let startsAt = upNextStart {
            ReachedWatcher(time: model.time, at: startsAt) { upNextShowing = $0 }
        }
    }

    /// The learned intro, for files without chapters.
    private var learnedSkip: (start: Double, end: Double)? {
        guard settings.showSkipButtons, session.target.episode != nil,
              !model.chapters.contains(where: { ChapterKind($0.name) == .intro }),
              let learned = learnedIntro, let start = learned.introStart, let end = learned.introEnd else { return nil }
        return (start, end)
    }

    /// Skip Intro and Up Next, bottom right. Buttons while the controls are up; while they are
    /// hidden, a prompt that Select answers.
    private var cornerActions: some View {
        VStack(alignment: .trailing, spacing: 20) {
            if let offer = skipOffer, !(upNextShowing && !upNextDismissed) {
                Button { model.seek(to: offer.to) } label: {
                    Label(offer.title.localized, systemImage: "forward.end.fill").font(.headline).padding(.horizontal, 8)
                }
                .buttonStyle(.glassProminent)
                .disabled(!controlsVisible)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            if let nextEpisode, upNextShowing, !upNextDismissed {
                TVUpNextCard(next: nextEpisode, countdown: settings.autoPlayNext, isPlaying: model.isPlaying,
                             interactive: controlsVisible, play: playNext) { upNextDismissed = true }
            }
        }
        .padding(.trailing, 80)
        .animation(.spring(duration: 0.35), value: skipOffer)
        .animation(.spring(duration: 0.35), value: upNextShowing)
    }

    private var controls: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.65), .clear, .clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 0) {
                header
                Spacer(minLength: 0)
                if let error = model.errorMessage {
                    errorCard(error).frame(maxWidth: .infinity)
                    Spacer(minLength: 0)
                } else {
                    timeline
                    buttonRow.padding(.top, 28)
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 50)
        }
        .onExitCommand { hideControls() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.target.item.name).font(.title2.weight(.bold)).lineLimit(1)
            if let episode = session.target.episode {
                Text("\(episode.code) · \(episode.title)").font(.headline).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
            }
            HStack(spacing: 10) {
                PlayerChip(text: session.source.quality)
                if let format = PlayerView.formatLabel(model.videoFormat) { PlayerChip(text: format, highlighted: true) }
                if let audio = activeAudioTrack {
                    if audio.isAtmos { PlayerChip(text: "Dolby Atmos", highlighted: true) }
                    else if let layout = TrackLabel.channels(audio.channels), audio.channels > 2 { PlayerChip(text: layout) }
                }
                if let size = session.source.size { PlayerChip(text: size) }
            }
            .padding(.top, 4)
        }
    }

    /// The timeline takes focus with the controls. Left and right move a preview; Select jumps.
    private var timeline: some View {
        TimelineBar(time: model.time, duration: model.duration, chapters: model.chapters,
                    preview: { await model.thumbnail(at: $0) }, scrubbing: scrubbing,
                    onChange: { scrubbing = $0 }, onCommit: { commitScrub(to: $0) })
            .padding(.vertical, 16)
            .padding(.horizontal, 20)
            .background(TimelineFocus())
            .focusable(controlsVisible && panel == nil && model.errorMessage == nil)
            .focused($focus, equals: .timeline)
            .onMoveCommand { direction in
                switch direction {
                case .left: scrub(-1)
                case .right: scrub(1)
                default: break
                }
            }
            .onTapGesture {
                if let scrubbing { commitScrub(to: scrubbing) } else { model.togglePlay() }
            }
            .onPlayPauseCommand {
                if let scrubbing { commitScrub(to: scrubbing) }
                model.togglePlay()
            }
            .onExitCommand {
                if scrubbing != nil { scrubbing = nil; scheduleHide() } else { hideControls() }
            }
    }

    private var buttonRow: some View {
        HStack(spacing: 18) {
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.headline).frame(width: 30)
            }
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
            Button { playback.switchSource(for: session.target) } label: { Label("Sources", systemImage: "list.bullet.rectangle") }
            Button { openPanel(.audio) } label: { Label("Audio & Subtitles", systemImage: "captions.bubble") }
            Button { openPanel(.speed) } label: { Label(PlayerView.rateLabel(model.rate).localized, systemImage: "gauge.with.dots.needle.67percent") }
            Button { openPanel(.info) } label: { Image(systemName: "info.circle").font(.headline) }
                .accessibilityLabel("Playback info")
            if model.sleepTimer != nil {
                Image(systemName: "moon.zzz.fill").foregroundStyle(Theme.accent)
                    .accessibilityLabel(model.sleepTimer?.title ?? "Sleep timer on")
            }
            Spacer(minLength: 0)
            if model.pip.isPossible {
                Button { model.pip.toggle() } label: { Image(systemName: "pip.enter").font(.headline) }
                    .accessibilityLabel("Picture in Picture")
            }
            Button { model.fillsScreen.toggle() } label: {
                Image(systemName: model.fillsScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.headline)
            }
            .accessibilityLabel(model.fillsScreen ? "Fit to screen" : "Fill screen")
        }
        .buttonStyle(.glass)
        .font(.headline)
        .focusSection()
    }

    @ViewBuilder private var optionsPanel: some View {
        if let tab = panel {
            Color.black.opacity(0.35).ignoresSafeArea().transition(.opacity).allowsHitTesting(false)
            OptionsPanel(model: model, tab: tab, wide: true, searchOnline: searchSubtitles) { closePanel() }
                .focusSection()
                .onExitCommand { closePanel() }
                .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    @ViewBuilder private var fallbackNotice: some View {
        if let notice = playback.fallbackNotice {
            HStack(spacing: 12) {
                ProgressView().tint(.white)
                Text(notice).font(.headline)
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
            .glassEffect(.regular, in: .capsule)
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 60)
            .transition(.opacity)
        }
    }

    private func notice(_ text: String, _ symbol: String) -> some View {
        Label(text.localized, systemImage: symbol)
            .font(.headline)
            .padding(.horizontal, 20).padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 60)
            .allowsHitTesting(false)
    }

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
            Text("This source couldn't be played").font(.title3.weight(.bold))
            Text(message).font(.callout).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
            HStack(spacing: 20) {
                if !session.isLocal {
                    Button(reconnecting ? "Retrying…" : "Retry") { reconnect() }
                        .buttonStyle(.glassProminent)
                        .disabled(reconnecting)
                }
                Button("Try Another Source") { playback.switchSource(for: session.target) }.buttonStyle(.glass)
                Button("Close") { dismiss() }.buttonStyle(.glass)
            }
        }
        .padding(40)
        .frame(maxWidth: 820)
        .glassEffect(.regular, in: .rect(cornerRadius: 36))
        .focusSection()
        .onExitCommand { dismiss() }
    }

    private var activeAudioTrack: TrackInfo? {
        model.audioTracks.first { $0.id == model.activeAudio } ?? model.audioTracks.first { $0.isDefault }
    }

    private var upNextStart: Double? {
        guard model.duration > 300 else { return nil }
        return model.chapters.creditsStart(duration: model.duration) ?? model.duration - 35
    }

    // MARK: Remote

    private func select() {
        if let nextEpisode = nextEpisode, upNextShowing, !upNextDismissed {
            _ = nextEpisode
            playNext()
        } else if let offer = skipOffer {
            model.seek(to: offer.to)
        } else {
            showControls()
        }
    }

    private func skip(_ seconds: Double) {
        model.skip(seconds)
        withAnimation(.easeOut(duration: 0.2)) { skipFlash = SkipFlash(forward: seconds > 0) }
        let flash = skipFlash
        Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            if skipFlash == flash { withAnimation(.easeIn(duration: 0.25)) { skipFlash = nil } }
        }
    }

    /// One step of the scrubber: 10 s, growing to 30 s and a minute while presses keep coming.
    private func scrub(_ direction: Double) {
        hideTask?.cancel()
        let now = Date()
        scrubStreak = now.timeIntervalSince(lastScrubStep) < 0.45 ? scrubStreak + 1 : 0
        lastScrubStep = now
        let step: Double = scrubStreak > 12 ? 60 : (scrubStreak > 4 ? 30 : 10)
        let from = scrubbing ?? model.currentTime
        scrubbing = min(max(0, from + direction * step), max(0, model.duration - 1))
    }

    private func commitScrub(to value: Double) {
        learnIntro(from: model.currentTime, to: value)
        model.seek(to: value)
        scrubbing = nil
        scheduleHide()
    }

    private func showControls() {
        controlsVisible = true
        scheduleHide()
        Task { @MainActor in
            await Task.yield()
            if panel == nil && model.errorMessage == nil { focus = .timeline }
        }
    }

    private func hideControls() {
        guard model.errorMessage == nil else { return }
        hideTask?.cancel()
        scrubbing = nil
        controlsVisible = false
        Task { @MainActor in
            await Task.yield()
            focus = .catcher
        }
    }

    private func openPanel(_ tab: OptionsPanel.Tab) {
        hideTask?.cancel()
        scrubbing = nil
        panel = tab
    }

    private func closePanel() {
        panel = nil
        showControls()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, model.isPlaying, scrubbing == nil, panel == nil,
                  !ProcessInfo.processInfo.arguments.contains("-ReelShot") else { return }
            hideControls()
        }
    }

    // MARK: Lifecycle

    private func start() {
        let target = session.target
        let choice = ViewingPreferences.choice(for: target.item.id)
        learnedIntro = choice
        let audio = choice?.audioLanguage.map { Languages.codes(for: $0) } ?? Languages.codes(for: settings.preferredAudioLanguage)
        let subtitles: [String]
        if let chosen = choice?.subtitleLanguage {
            subtitles = chosen.isEmpty ? [] : Languages.codes(for: chosen)
        } else {
            subtitles = settings.autoplaySubtitles ? Languages.codes(for: settings.preferredSubtitleLanguage) : []
        }
        if let choice {
            model.fillsScreen = choice.fillsScreen
            if choice.subtitleDelay != 0 { model.setSubtitleDelay(choice.subtitleDelay) }
        }
        model.start(
            url: session.url,
            title: target.item.name,
            subtitle: target.episode.map { "\($0.code) · \($0.title)" },
            startAt: session.startAt,
            audioLanguages: audio,
            subtitleLanguages: subtitles,
            artwork: target.episode?.thumbnail ?? target.item.poster,
            localSubtitles: session.localSubtitles,
            audioShaping: settings.audioShaping,
            onProgress: { [weak lib = library, isCloud = session.isCloud] position, duration in
                guard !isCloud else { return }
                lib?.record(target, position: position, duration: duration, live: true)
            }
        )
        showControls()
    }

    private func started() {
        guard !reportedStart else { return }
        reportedStart = true
        playback.playerStarted(session)
        if let rate = ViewingPreferences.choice(for: session.target.item.id)?.rate, rate != 1 { model.setRate(rate) }
        if settings.autoplaySubtitles && settings.searchOnlineSubtitles && !settings.preferredSubtitleLanguage.isEmpty {
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                model.searchOnlineSubtitles(kind: session.target.item.kind, videoID: session.target.videoID,
                                            filename: session.source.file ?? session.source.release,
                                            size: session.source.sizeBytes,
                                            autoAdd: Languages.codes(for: settings.preferredSubtitleLanguage))
            }
        }
    }

    private func failed(_ message: String) {
        if model.hasFirstFrame || reportedStart {
            if reconnects == 0 { reconnect() }
            return
        }
        guard !handledFailure else { return }
        handledFailure = true
        if playback.playerFailed(session, reason: message, position: nil, offline: NetworkMonitor.shared.isOffline,
                                 settings: settings) {
            model.stop()
        }
    }

    private func reconnect() {
        guard !reconnecting else { return }
        reconnecting = true
        reconnects += 1
        let position = model.currentTime
        Task {
            defer { reconnecting = false }
            do {
                let url = try await playback.reconnect(session, settings: settings)
                model.reload(url: url, at: position)
            } catch {
                // The error card stays, with Retry.
            }
        }
    }

    private func finish() {
        hideTask?.cancel()
        rememberChoices()
        scrobble(.stop)
        model.stop()
        library.commitLive()
    }

    private func ended() {
        if nextEpisode != nil && settings.autoPlayNext && !model.stopsAtEnd {
            playNext()
        } else {
            dismiss()
        }
    }

    private func rememberChoices() {
        guard model.hasFirstFrame, !session.isCloud else { return }
        let audio = model.audioTracks.first { $0.id == model.activeAudio }?.language
        let wouldAutoplay = settings.autoplaySubtitles
            && model.subtitleTracks.contains { Languages.matches($0.language ?? "", preferred: settings.preferredSubtitleLanguage) }
        let subtitle: String? = model.activeSubtitle == nil
            ? (wouldAutoplay ? "" : nil)
            : model.subtitleTracks.first { $0.id == model.activeSubtitle }?.language
        let previous = ViewingPreferences.choice(for: session.target.item.id)
        var choice = ViewingChoice(audioLanguage: audio.flatMap { $0.isEmpty || $0 == "und" ? nil : $0 },
                                   subtitleLanguage: subtitle.flatMap { $0 == "und" ? nil : $0 },
                                   subtitleDelay: model.subtitleDelay, fillsScreen: model.fillsScreen,
                                   rate: model.boosted ? 1 : model.rate)
        choice.introStart = previous?.introStart
        choice.introEnd = previous?.introEnd
        ViewingPreferences.store(choice, for: session.target.item.id)
    }

    /// A scrub forward of between 20 s and 3 minutes in an episode's first ten minutes is taken as
    /// skipping its intro, and offered again in the episodes that follow.
    private func learnIntro(from start: Double, to end: Double) {
        guard session.target.episode != nil, start < 600, (20...180).contains(end - start) else { return }
        var choice = ViewingPreferences.choice(for: session.target.item.id) ?? ViewingChoice()
        choice.introStart = start
        choice.introEnd = end
        choice.updatedAt = Date()
        ViewingPreferences.store(choice, for: session.target.item.id)
    }

    private func scrobble(_ action: Trakt.ScrobbleAction) {
        guard !session.isCloud, !sentStop else { return }
        if action == .stop { sentStop = true }
        trakt.scrobble(action, target: session.target, position: model.currentTime, duration: model.duration)
    }

    private func searchSubtitles() {
        model.searchOnlineSubtitles(kind: session.target.item.kind, videoID: session.target.videoID,
                                    filename: session.source.file ?? session.source.release, size: session.source.sizeBytes)
    }

    private func loadNextEpisode() async {
        guard let current = session.target.episode,
              let detail = try? await Cinemeta.detail(.series, id: session.target.item.id) else { return }
        library.learnEpisodes(detail)
        let ordered = detail.episodes.filter { $0.season > 0 }.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
        guard let index = ordered.firstIndex(where: { $0.id == current.id }), ordered.indices.contains(index + 1) else { return }
        let next = ordered[index + 1]
        guard next.hasAired else { return }
        nextEpisode = next
        playback.prefetch(PlaybackTarget(item: session.target.item, episode: next), settings: settings,
                          immediately: true, prepare: false)
    }

    private func playNext() {
        guard let nextEpisode else { return }
        scrobble(.stop)
        library.record(session.target, position: model.duration, duration: model.duration, live: true)
        playback.playNext(PlaybackTarget(item: session.target.item, episode: nextEpisode), after: session,
                          settings: settings, library: library)
    }
}

/// The highlight behind the timeline while it has focus.
private struct TimelineFocus: View {
    @Environment(\.isFocused) private var focused

    var body: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(.white.opacity(focused ? 0.12 : 0))
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

/// Watches the clock for a chapter or learned intro to skip, and reports it only when it changes,
/// so the player itself doesn't redraw ten times a second.
private struct SkipWatcher: View {
    var time: PlaybackTime
    let chapters: [ChapterInfo]
    let duration: Double
    let skipsCredits: Bool
    let learned: (start: Double, end: Double)?
    let report: (PlayerView.SkipOffer?) -> Void

    var body: some View {
        let offer = current(time.currentTime)
        Color.clear.frame(width: 0, height: 0)
            .onChange(of: offer, initial: true) { _, value in report(value) }
            .accessibilityHidden(true)
    }

    private func current(_ now: Double) -> PlayerView.SkipOffer? {
        if let chapter = chapters.first(where: { now >= $0.startSeconds + 1 && now < $0.startSeconds + $0.durationSeconds - 3 }) {
            let kind = ChapterKind(chapter.name)
            if let title = kind.skipTitle, kind != .credits || skipsCredits {
                return .init(title: title, to: min(chapter.startSeconds + chapter.durationSeconds, max(duration - 1, 0)))
            }
        }
        if let learned, now >= max(0, learned.start - 15), now < learned.end - 5 {
            return .init(title: "Skip Intro", to: learned.end)
        }
        return nil
    }
}

/// Reports whether the playhead has reached a time, once per change.
private struct ReachedWatcher: View {
    var time: PlaybackTime
    let at: Double
    let report: (Bool) -> Void

    var body: some View {
        let reached = time.currentTime >= at
        Color.clear.frame(width: 0, height: 0)
            .onChange(of: reached, initial: true) { _, value in report(value) }
            .accessibilityHidden(true)
    }
}

/// Up Next near the end of an episode, with a countdown when autoplay is on. With the controls
/// hidden it is a prompt: Select plays, Back dismisses.
private struct TVUpNextCard: View {
    let next: Episode
    let countdown: Bool
    let isPlaying: Bool
    let interactive: Bool
    let play: () -> Void
    let cancel: () -> Void
    @State private var remaining = 10

    var body: some View {
        HStack(spacing: 22) {
            RemoteImage(url: next.thumbnail, targetWidth: 300)
                .frame(width: 256, height: 144)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 8) {
                Text("UP NEXT").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.6))
                Text("\(next.code) · \(next.title)").font(.headline).lineLimit(2)
                if interactive {
                    HStack(spacing: 14) {
                        Button(action: play) {
                            Label(countdown ? "Play in \(remaining)" : "Play Now", systemImage: "play.fill")
                                .contentTransition(.numericText())
                        }
                        .buttonStyle(.glassProminent)
                        Button("Cancel", action: cancel).buttonStyle(.glass)
                    }
                } else {
                    Text(countdown ? "Plays in \(remaining) s · Select to play now" : "Select to play")
                        .font(.callout).foregroundStyle(.white.opacity(0.75))
                        .contentTransition(.numericText())
                }
            }
        }
        .padding(20)
        .glassEffect(.regular, in: .rect(cornerRadius: 30))
        .frame(maxWidth: 760)
        .focusSection()
        .transition(.move(edge: .trailing).combined(with: .opacity))
        .task(id: isPlaying) {
            guard countdown, isPlaying else { return }
            while remaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                withAnimation { remaining -= 1 }
            }
            play()
        }
    }
}
