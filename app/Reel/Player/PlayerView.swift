import SwiftUI
import AVKit
import AetherEngine

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
    @State private var width: CGFloat = 400
    @State private var nextEpisode: Episode?
    @State private var reportedStart = false
    @State private var handledFailure = false
    @State private var reconnecting = false
    @State private var reconnects = 0
    /// Which side a double tap skipped, for the brief arrow drawn there.
    @State private var skipFlash: SkipFlash?
    @State private var pinchScale: CGFloat = 1
    @State private var boostTask: Task<Void, Never>?
    /// The intro skip learned in an earlier episode, read once when the player opens.
    @State private var learnedIntro: ViewingChoice?
    @State private var preparedNext = false

    struct SkipFlash: Equatable { let forward: Bool; let id = UUID() }
    /// The fold, when an iPhone Duo stands half-open like a laptop: the picture goes above it and
    /// the controls below, instead of both bending across the crease.
    @State private var fold: CGRect?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let fold {
                tabletop(fold)
            } else {
                fullScreen
            }
        }
        .foldObserver($fold)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .statusBarHidden(!controlsVisible && fold == nil)
        .persistentSystemOverlays(controlsVisible || fold != nil ? .automatic : .hidden)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.22), value: controlsVisible)
        .animation(.spring(duration: 0.35), value: panel)
        .animation(.easeOut(duration: 0.3), value: model.hasFirstFrame)
        .animation(.spring(duration: 0.45), value: fold)
        .onAppear(perform: start)
        .onDisappear(perform: finish)
        .task { await loadNextEpisode() }
        .onChange(of: model.isPlaying) { _, playing in
            if playing { scheduleHide() }
            scrobble(playing ? .start : .pause)
        }
        .onChange(of: model.state) { _, state in if state == .ended { ended() } }
        .onChange(of: model.hasFirstFrame) { _, ready in if ready { started() } }
        .onChange(of: model.errorMessage) { _, message in if let message { failed(message) } }
        .onChange(of: model.stallCount) { _, _ in playback.playerStalled(session) }
        .onChange(of: settings.audioShaping) { _, shaping in model.setAudioShaping(shaping) }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            model.restoreAfterBackground()
            controlsVisible = true
            scheduleHide()
        }
    }

    // MARK: Layouts

    private var fullScreen: some View {
        ZStack {
            picture
            SubtitleOverlay(feed: model.subtitles, bottomInset: controlsVisible ? 150 : 36, appearance: subtitleAppearance)

            // Owns the touches above the video: one tap shows or hides the controls; two taps on
            // the left or right third skip back or ahead 10 s, two in the middle toggle fill;
            // pinching fills or fits; holding plays at double speed until released.
            GeometryReader { proxy in
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, coordinateSpace: .local) { location in
                        doubleTap(at: location.x, width: proxy.size.width)
                    }
                    .onTapGesture { toggleControls() }
                    .onLongPressGesture(minimumDuration: 0.45, maximumDistance: 30) {
                    } onPressingChanged: { pressing in
                        // Pressing starts at touch-down; only a press still held after a moment
                        // is a hold, so a tap never flickers into double speed.
                        boostTask?.cancel()
                        if pressing {
                            boostTask = Task {
                                try? await Task.sleep(nanoseconds: 450_000_000)
                                if !Task.isCancelled { model.beginBoost() }
                            }
                        } else {
                            model.endBoost()
                        }
                    }
                    .simultaneousGesture(
                        MagnifyGesture()
                            .onChanged { pinchScale = $0.magnification }
                            .onEnded { value in
                                if value.magnification > 1.15 { model.fillsScreen = true }
                                if value.magnification < 0.87 { model.fillsScreen = false }
                                pinchScale = 1
                            }
                    )
            }
            .ignoresSafeArea()

            if let skipFlash {
                SkipFlashView(forward: skipFlash.forward)
                    .id(skipFlash.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: skipFlash.forward ? .trailing : .leading)
                    .padding(.horizontal, 60)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            if model.boosted {
                Label("2× speed", systemImage: "forward.fill")
                    .font(.subheadline.weight(.bold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 70)
                    .allowsHitTesting(false)
            }
            if model.sleepFired && !model.isPlaying {
                Label("Paused by the sleep timer", systemImage: "moon.zzz.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 70)
                    .allowsHitTesting(false)
            }
            keyboardShortcuts

            if model.isBusy && model.hasFirstFrame {
                ProgressView().controlSize(.large).tint(.white).allowsHitTesting(false)
            }

            if controlsVisible || model.errorMessage != nil {
                controls.transition(.opacity)
            }

            cornerActions
                .padding(.horizontal, 20)
                .padding(.bottom, controlsVisible ? 170 : 40)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

            optionsPanel
            fallbackNotice
        }
    }

    /// Half-open on a table: picture above the fold, everything you touch below it.
    private func tabletop(_ fold: CGRect) -> some View {
        VStack(spacing: 0) {
            ZStack {
                picture
                SubtitleOverlay(feed: model.subtitles, bottomInset: 16, appearance: subtitleAppearance)
                Color.clear.contentShape(Rectangle())
                    .onTapGesture(count: 2) { model.fillsScreen.toggle() }
                if model.isBusy && model.hasFirstFrame {
                    ProgressView().controlSize(.large).tint(.white).allowsHitTesting(false)
                }
            }
            .frame(height: max(fold.minY, 120))
            .clipped()

            Color.black.frame(height: fold.height)

            ZStack {
                VStack(spacing: 14) {
                    topBar
                    Spacer(minLength: 0)
                    if let error = model.errorMessage { errorCard(error) } else { transport }
                    HStack { Spacer(); cornerActions }
                    Spacer(minLength: 0)
                    bottomBar
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                optionsPanel
            }
            .frame(maxHeight: .infinity)
        }
        .ignoresSafeArea(edges: .top)
        .overlay { fallbackNotice }
    }

    private var picture: some View {
        ZStack {
            if let engine = model.engine {
                AetherPlayerSurface(engine: engine)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            if !model.hasFirstFrame && model.errorMessage == nil {
                StartupCover(session: session)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder private var optionsPanel: some View {
        if let tab = panel {
            Color.black.opacity(0.35).ignoresSafeArea()
                .onTapGesture { closePanel() }
                .transition(.opacity)
            OptionsPanel(model: model, tab: tab, wide: width >= 640, searchOnline: searchSubtitles) { closePanel() }
                .transition(.move(edge: width >= 640 ? .trailing : .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder private var fallbackNotice: some View {
        if let notice = playback.fallbackNotice {
            HStack(spacing: 10) {
                ProgressView().tint(.white)
                Text(notice).font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 60)
            .transition(.opacity)
        }
    }

    /// Skip Intro and Up Next, bottom right, above the controls.
    private var cornerActions: some View {
        VStack(alignment: .trailing, spacing: 12) {
            if settings.showSkipButtons && !model.chapters.isEmpty {
                SkipChapterButton(time: model.time, chapters: model.chapters, duration: model.duration,
                                  skipsCredits: nextEpisode == nil) { model.seek(to: $0) }
            }
            if settings.showSkipButtons, session.target.episode != nil,
               !model.chapters.contains(where: { ChapterKind($0.name) == .intro }),
               let learned = learnedIntro, let start = learned.introStart, let end = learned.introEnd {
                LearnedSkipButton(time: model.time, start: start, end: end) { model.seek(to: $0) }
            }
            if (settings.autoSkipIntro || settings.autoSkipRecap) && !model.chapters.isEmpty {
                AutoSkipper(time: model.time, chapters: model.chapters, duration: model.duration,
                            intro: settings.autoSkipIntro, recap: settings.autoSkipRecap) { model.seek(to: $0) }
            }
            if let nextEpisode, let startsAt = upNextStart, !preparedNext {
                // A minute and a half before Up Next, get its stream ready so it starts at once.
                TimeTrigger(time: model.time, at: max(0, startsAt - 90)) {
                    preparedNext = true
                    playback.prefetch(PlaybackTarget(item: session.target.item, episode: nextEpisode), settings: settings,
                                      immediately: true, prepare: settings.autoPlayNext)
                }
            }
            if let nextEpisode, let startsAt = upNextStart {
                UpNextCard(time: model.time, next: nextEpisode, showName: session.target.item.name, startsAt: startsAt,
                           countdown: settings.autoPlayNext, isPlaying: model.isPlaying) { playNext() }
            }
        }
        .animation(.spring(duration: 0.35), value: model.chapters.count)
    }

    private var upNextStart: Double? {
        guard model.duration > 300 else { return nil }
        return model.chapters.creditsStart(duration: model.duration) ?? model.duration - 35
    }

    private var subtitleAppearance: SubtitleAppearance {
        settings.subtitleAppearance
    }

    // MARK: Lifecycle

    private func start() {
        let target = session.target
        // The way this film or series was left last time wins over the general settings.
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
        scheduleHide()
    }

    private func started() {
        guard !reportedStart else { return }
        reportedStart = true
        playback.playerStarted(session)
        if let rate = ViewingPreferences.choice(for: session.target.item.id)?.rate, rate != 1 { model.setRate(rate) }
        // With subtitles wanted and none in the file in that language, fetch one from OpenSubtitles.
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
        // A stream that played and then failed (an expired debrid link, a long pause) is opened
        // again from a fresh link at the same place, once, before the error card shows. It is
        // not a mark against the source.
        if model.hasFirstFrame || reportedStart {
            if reconnects == 0 { reconnect() }
            return
        }
        // A source that never showed a picture failed to open: move on to the next, unless the
        // device is simply offline.
        guard !handledFailure else { return }
        handledFailure = true
        if playback.playerFailed(session, reason: message, position: nil, offline: NetworkMonitor.shared.isOffline,
                                 settings: settings) {
            model.stop()
        }
    }

    /// Resolves the same release again and reloads it where it stopped.
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

    /// What the viewer picked here, for the next episode or the next time.
    private func rememberChoices() {
        guard model.hasFirstFrame, !session.isCloud else { return }
        let audio = model.audioTracks.first { $0.id == model.activeAudio }?.language
        // "Off" is remembered only when subtitles would otherwise have come on by themselves.
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

    /// A drag forward of between 20 s and 3 minutes in an episode's first ten minutes is taken as
    /// skipping its intro, and offered again in the episodes that follow.
    private func learnIntro(from start: Double, to end: Double) {
        guard session.target.episode != nil, start < 600, (20...180).contains(end - start) else { return }
        var choice = ViewingPreferences.choice(for: session.target.item.id) ?? ViewingChoice()
        choice.introStart = start
        choice.introEnd = end
        choice.updatedAt = Date()
        ViewingPreferences.store(choice, for: session.target.item.id)
    }

    private func doubleTap(at x: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        let third = x / width
        if third < 0.33 || third > 0.67 {
            let forward = third > 0.67
            model.skip(forward ? 10 : -10)
            withAnimation(.easeOut(duration: 0.2)) { skipFlash = SkipFlash(forward: forward) }
            let flash = skipFlash
            Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                if skipFlash == flash { withAnimation(.easeIn(duration: 0.25)) { skipFlash = nil } }
            }
        } else {
            model.fillsScreen.toggle()
        }
    }

    /// A hardware keyboard: space plays and pauses, arrows skip, F fills, C turns subtitles on
    /// and off, Esc closes. Hidden buttons, so they work without focus and show in the ⌘ overlay.
    private var keyboardShortcuts: some View {
        ZStack {
            Button("Play or Pause") { model.togglePlay(); scheduleHide() }.keyboardShortcut(.space, modifiers: [])
            Button("Back 10 Seconds") { model.skip(-10) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("Ahead 10 Seconds") { model.skip(10) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("Back 1 Minute") { model.skip(-60) }.keyboardShortcut(.leftArrow, modifiers: [.shift])
            Button("Ahead 1 Minute") { model.skip(60) }.keyboardShortcut(.rightArrow, modifiers: [.shift])
            Button("Fill Screen") { model.fillsScreen.toggle() }.keyboardShortcut("f", modifiers: [])
            Button("Subtitles") { toggleSubtitles() }.keyboardShortcut("c", modifiers: [])
            Button("Close Player") { dismiss() }.keyboardShortcut(.escape, modifiers: [])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func toggleSubtitles() {
        if model.activeSubtitle != nil {
            model.selectSubtitle(nil)
        } else if let track = model.subtitleTracks.first(where: { Languages.matches($0.language ?? "", preferred: settings.preferredSubtitleLanguage) })
                    ?? model.subtitleTracks.first {
            model.selectSubtitle(track)
        }
    }

    private func scrobble(_ action: Trakt.ScrobbleAction) {
        guard !session.isCloud else { return }
        trakt.scrobble(action, target: session.target, position: model.currentTime, duration: model.duration)
    }

    private func searchSubtitles() {
        model.searchOnlineSubtitles(kind: session.target.item.kind, videoID: session.target.videoID,
                                    filename: session.source.file ?? session.source.release, size: session.source.sizeBytes)
    }

    // MARK: Next episode

    private func loadNextEpisode() async {
        guard let current = session.target.episode,
              let detail = try? await Cinemeta.detail(.series, id: session.target.item.id) else { return }
        library.learnEpisodes(detail)
        let ordered = detail.episodes.filter { $0.season > 0 }.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
        guard let index = ordered.firstIndex(where: { $0.id == current.id }), ordered.indices.contains(index + 1) else { return }
        let next = ordered[index + 1]
        guard next.hasAired else { return }
        nextEpisode = next
        // Look its sources up now, so the switch at the credits is quick.
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
            Button { openPanel(.info) } label: {
                Image(systemName: "info.circle").font(.headline).frame(width: 22, height: 22)
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Playback info")
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
            TimelineBar(
                time: model.time,
                duration: model.duration,
                chapters: model.chapters,
                preview: { await model.thumbnail(at: $0) },
                scrubbing: scrubbing,
                onChange: { scrubbing = $0; hideTask?.cancel() },
                onCommit: { value in
                    learnIntro(from: model.currentTime, to: value)
                    model.seek(to: value)
                    scrubbing = nil
                    scheduleHide()
                }
            )

            HStack(spacing: 10) {
                barButton("Sources", "list.bullet.rectangle") { playback.switchSource(for: session.target) }
                barButton("Audio & Subtitles", "captions.bubble") { openPanel(.audio) }
                barButton(Self.rateLabel(model.rate), "gauge.with.dots.needle.67percent") { openPanel(.speed) }
                if model.sleepTimer != nil {
                    Image(systemName: "moon.zzz.fill").font(.subheadline).foregroundStyle(Theme.accent)
                        .accessibilityLabel(model.sleepTimer?.title ?? "Sleep timer on")
                }
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
            Label(title.localized, systemImage: symbol)
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
                if !session.isLocal {
                    Button(reconnecting ? "Retrying…" : "Retry") { reconnect() }
                        .buttonStyle(.glassProminent)
                        .disabled(reconnecting)
                }
                Button("Try Another Source") { playback.switchSource(for: session.target) }
                    .buttonStyle(.glass)
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
            guard !Task.isCancelled, model.isPlaying, scrubbing == nil, panel == nil,
                  !ProcessInfo.processInfo.arguments.contains("-ReelShot") else { return }
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
