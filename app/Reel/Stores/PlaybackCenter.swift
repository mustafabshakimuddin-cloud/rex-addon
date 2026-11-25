import Foundation
import Combine
import AetherEngine

/// What the player opens with: a resolved, directly playable address.
struct PlayerSession: Identifiable, Equatable {
    let id = UUID()
    let target: PlaybackTarget
    let url: URL
    let source: StreamSource
    let startAt: Double?
    /// What to try next, in order, if this source fails before its first picture. Empty for a
    /// source the user picked by hand: they chose it, so they decide what happens next.
    var alternates: [StreamSource] = []
    var isLocal = false
    /// A downloaded subtitle file to add as a track, for offline copies.
    var localSubtitles: [URL] = []
}

/// Turns "play this" into a running player: find sources across Torrentio and the user's addons,
/// rank them by what has actually played before, resolve the best through the debrid service
/// (falling back to the next if one fails, before or after the player opens), and present it.
@MainActor
final class PlaybackCenter: ObservableObject {
    @Published var session: PlayerSession?
    @Published private(set) var preparing: PlaybackTarget?
    @Published var errorMessage: String?
    @Published var needsDebridSetup = false
    /// Set to show the source list for a title; RootView presents it.
    @Published var choosingSource: PlaybackTarget?
    /// Shown briefly over the player while a failed source is being replaced.
    @Published private(set) var fallbackNotice: String?
    /// Whether the source picked from that list should start over rather than resume.
    private(set) var chooseFromStart = false

    let memory: SourceMemory
    let downloads: DownloadStore

    private var work: Task<Void, Never>?
    private var prefetchTasks: [String: Task<Void, Never>] = [:]
    private var sourceCache: [String: CachedSources] = [:]
    private var resolvedCache: [String: (url: URL, at: Date)] = [:]
    /// Run once the player's full-screen cover has finished closing (RootView calls
    /// `playerDismissed`), instead of guessing how long the animation takes.
    private var afterDismiss: (() -> Void)?
    private static let maxAttempts = 3
    private static let sourceLifetime: TimeInterval = 10 * 60
    private static let resolvedLifetime: TimeInterval = 30 * 60

    private struct CachedSources {
        let query: SourceQuery
        let sources: [StreamSource]
        let at: Date
    }

    init(memory: SourceMemory, downloads: DownloadStore) {
        self.memory = memory
        self.downloads = downloads
    }

    // MARK: Sources

    /// Every source for a title, from a ten-minute cache when the same search ran recently, so the
    /// list opens instantly after the title page has looked once.
    func sources(for target: PlaybackTarget, query: SourceQuery, refresh: Bool = false) async throws -> [StreamSource] {
        if !refresh, let cached = cachedSources(for: target, query: query) { return cached }
        let found = try await SourceFinder.find(kind: target.item.kind, videoID: target.videoID, query: query)
        sourceCache[target.videoID] = CachedSources(query: query, sources: found, at: Date())
        if sourceCache.count > 40, let oldest = sourceCache.min(by: { $0.value.at < $1.value.at })?.key {
            sourceCache[oldest] = nil
        }
        return found
    }

    func cachedSources(for target: PlaybackTarget, query: SourceQuery) -> [StreamSource]? {
        guard let cached = sourceCache[target.videoID], cached.query == query,
              Date().timeIntervalSince(cached.at) < Self.sourceLifetime else { return nil }
        return cached.sources
    }

    /// The final address of a source, reused for half an hour on the same debrid account: a
    /// debrid link stays valid far longer than that, and resolving twice adds the same torrent to
    /// the account twice.
    func resolve(_ source: StreamSource, account: String, fresh: Bool = false) async throws -> URL {
        let key = account + "|" + source.fileKey
        if !fresh, let hit = resolvedCache[key], Date().timeIntervalSince(hit.at) < Self.resolvedLifetime {
            return hit.url
        }
        let url = try await Torrentio.resolve(source)
        resolvedCache[key] = (url, Date())
        return url
    }

    private func forgetResolved(_ source: StreamSource) {
        resolvedCache = resolvedCache.filter { !$0.key.hasSuffix("|" + source.fileKey) }
    }

    /// Called by a title page: look up its sources now so Play and the source list don't wait.
    /// With "Get streams ready" on, also resolve the likely pick and fetch its first bytes. A
    /// second after the page opens, so flicking through titles doesn't search for each one.
    func prefetch(_ target: PlaybackTarget, settings: AppSettings, immediately: Bool = false, prepare: Bool? = nil) {
        guard settings.canFindSources else { return }
        let query = settings.sourceQuery
        let prepare = prepare ?? settings.prepareAhead
        let account = settings.torrentio.accountFingerprint
        let preferences = settings.sourcePreferences
        prefetchTasks[target.videoID]?.cancel()
        prefetchTasks[target.videoID] = Task { [weak self] in
            if !immediately { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            guard !Task.isCancelled, let self, let all = try? await self.sources(for: target, query: query) else { return }
            guard prepare, !Task.isCancelled,
                  let top = SourceRanker.rank(all, memory: self.memory, preferences: preferences).first(where: \.isCached),
                  let url = try? await self.resolve(top, account: account) else { return }
            await Task.detached(priority: .utility) { _ = await AetherEngine.prewarm(url: url) }.value
        }
    }

    /// The title page closed before its prefetch ran: don't search for it.
    func cancelPrefetch(_ target: PlaybackTarget) {
        prefetchTasks[target.videoID]?.cancel()
        prefetchTasks[target.videoID] = nil
    }

    /// Opens the file and reads its real format, then remembers the answer for the source list.
    func verify(_ source: StreamSource, settings: AppSettings) async throws -> SourceVerification {
        let url = try await resolve(source, account: settings.torrentio.accountFingerprint)
        let verification = try await SourceVerifier.verify(url: url)
        memory.store(verification, for: source)
        return verification
    }

    // MARK: Downloading

    /// Saves a title for offline viewing: the source given, or the one Play would have picked
    /// under the download size limit.
    func download(_ target: PlaybackTarget, settings: AppSettings, source: StreamSource? = nil) {
        guard settings.canFindSources else {
            needsDebridSetup = true
            return
        }
        let query = settings.downloadQuery
        let account = settings.torrentio.accountFingerprint
        let preferences = settings.sourcePreferences
        let options = DownloadStore.Options(settings)
        Task { [weak self] in
            guard let self else { return }
            do {
                let candidates: [StreamSource]
                if let source {
                    candidates = [source]
                } else {
                    let all = try await self.sources(for: target, query: query)
                    candidates = SourceRanker.rank(all, memory: self.memory, preferences: preferences).filter(\.isCached)
                }
                try self.downloads.checkSpace(for: candidates.first)
                var lastError: Error = PlaybackError.noSources(any: true)
                for candidate in candidates.prefix(3) {
                    do {
                        let url = try await self.resolve(candidate, account: account)
                        try self.downloads.start(target, source: candidate, url: url, options: options)
                        return
                    } catch let error as DownloadError {
                        throw error
                    } catch {
                        lastError = error
                    }
                }
                throw lastError
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Downloads several episodes in order (a season, or the next few), skipping those saved.
    func download(_ episodes: [Episode], of item: MediaItem, settings: AppSettings) {
        let targets = episodes.filter(\.hasAired).map { PlaybackTarget(item: item, episode: $0) }
            .filter { downloads.item(for: $0) == nil }
        guard !targets.isEmpty else { return }
        Task { [weak self] in
            for target in targets {
                guard let self else { return }
                self.download(target, settings: settings)
                // One search at a time is kinder to Torrentio and the debrid service.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    /// Retry from Downloads: with resume data the transfer carries on; otherwise, or when the old
    /// link was refused, the same release is resolved again for a fresh link, since debrid links
    /// expire.
    func retryDownload(_ item: DownloadItem, settings: AppSettings) {
        if downloads.canResumeInPlace(item) {
            downloads.resume(item)
            return
        }
        let account = settings.torrentio.accountFingerprint
        Task { [weak self] in
            guard let self else { return }
            do {
                self.forgetResolved(item.source)
                let url = try await self.resolve(item.source, account: account, fresh: true)
                self.downloads.restart(item, url: url)
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Playing

    func play(_ target: PlaybackTarget, settings: AppSettings, library: Library, source: StreamSource? = nil,
              fromStart: Bool = false, automatic: Bool = false, preferGroup: String? = nil) {
        let startAt = fromStart ? nil : library.resumePosition(for: target)
        // A finished download plays from the device, with no network and no debrid service.
        if source == nil, let local = downloads.completedFile(for: target) {
            errorMessage = nil
            session = PlayerSession(target: target, url: local.url, source: local.source, startAt: startAt, isLocal: true,
                                    localSubtitles: local.subtitles)
            return
        }
        guard settings.canFindSources else {
            needsDebridSetup = true
            return
        }
        // Unless "play the best source automatically" is on, Play opens the source list.
        if source == nil && !settings.autoPlayBest && !automatic {
            chooseSource(for: target, fromStart: fromStart)
            return
        }
        work?.cancel()
        preparing = target
        errorMessage = nil
        let query = settings.sourceQuery
        let account = settings.torrentio.accountFingerprint
        let preferences = settings.sourcePreferences
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let candidates: [StreamSource]
                if let source {
                    candidates = [source]
                } else {
                    let all = try await self.sources(for: target, query: query)
                    candidates = SourceRanker.rank(all, memory: self.memory, preferGroup: preferGroup, preferences: preferences)
                    guard !candidates.isEmpty else { throw PlaybackError.noSources(any: !all.isEmpty) }
                }
                try await self.open(target, candidates: candidates, startAt: startAt, account: account,
                                    attempts: source == nil ? Self.maxAttempts : 1, keepAlternates: source == nil)
            } catch is CancellationError {
                self.preparing = nil
            } catch {
                self.preparing = nil
                self.errorMessage = PlaybackError.describe(error)
            }
        }
    }

    /// Resolves candidates in order until one gives an address, then presents the player with the
    /// rest kept as alternates.
    private func open(_ target: PlaybackTarget, candidates: [StreamSource], startAt: Double?, account: String,
                      attempts: Int, keepAlternates: Bool) async throws {
        var lastError: Error?
        for (index, candidate) in candidates.prefix(attempts).enumerated() {
            try Task.checkCancellation()
            do {
                let url = try await resolve(candidate, account: account)
                try Task.checkCancellation()
                preparing = nil
                let rest = keepAlternates ? Array(candidates.dropFirst(index + 1).prefix(4)) : []
                session = PlayerSession(target: target, url: url, source: candidate, startAt: startAt, alternates: rest)
                return
            } catch let error as ResolveError where error == .accessDenied {
                throw error  // every source will fail the same way
            } catch is CancellationError {
                throw CancellationError()
            } catch let error where HTTP.isOffline(error) {
                // No network: the source isn't at fault, and the next one won't fare better.
                throw error
            } catch {
                memory.noteFailure(candidate, reason: error.localizedDescription)
                lastError = error
            }
        }
        throw lastError ?? PlaybackError.noSources(any: true)
    }

    /// The player reports its first picture: this source works.
    func playerStarted(_ session: PlayerSession) {
        guard !session.isLocal else { return }
        memory.noteSuccess(session.source)
    }

    func playerStalled(_ session: PlayerSession) {
        guard !session.isLocal else { return }
        memory.noteStall(session.source)
    }

    /// RootView: the player's cover has finished closing.
    func playerDismissed() {
        let next = afterDismiss
        afterDismiss = nil
        next?()
    }

    /// Closes the player, then runs `next` once it is off screen.
    private func closePlayer(then next: @escaping () -> Void) {
        if session == nil {
            next()
        } else {
            afterDismiss = next
            session = nil
        }
    }

    /// The player could not open its source. Remember that, and when the source was picked
    /// automatically, quietly move on to the next one. Returns whether a replacement is coming.
    @discardableResult
    func playerFailed(_ failed: PlayerSession, reason: String, position: Double?, offline: Bool = false,
                      settings: AppSettings) -> Bool {
        guard !failed.isLocal else { return false }
        forgetResolved(failed.source)
        if !offline { memory.noteFailure(failed.source, reason: reason) }
        guard !failed.alternates.isEmpty, !offline else { return false }
        fallbackNotice = "That source didn't open. Trying the next one…"
        let startAt = position.flatMap { $0 > 5 ? $0 : nil } ?? failed.startAt
        let account = settings.torrentio.accountFingerprint
        work?.cancel()
        preparing = failed.target
        closePlayer { [weak self] in
            guard let self else { return }
            self.work = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.open(failed.target, candidates: failed.alternates, startAt: startAt, account: account,
                                        attempts: Self.maxAttempts, keepAlternates: true)
                } catch is CancellationError {
                    self.preparing = nil
                } catch {
                    self.preparing = nil
                    self.errorMessage = PlaybackError.describe(error)
                }
                self.fallbackNotice = nil
            }
        }
        return true
    }

    /// The link of a source that was playing stopped working (a debrid link expired, a long
    /// pause): resolve the same release again for a fresh address. The player reloads it.
    func reconnect(_ session: PlayerSession, settings: AppSettings) async throws -> URL {
        guard !session.isLocal else { return session.url }
        forgetResolved(session.source)
        return try await resolve(session.source, account: settings.torrentio.accountFingerprint, fresh: true)
    }

    func chooseSource(for target: PlaybackTarget, fromStart: Bool = false) {
        chooseFromStart = fromStart
        choosingSource = target
    }

    /// From the player: close it (its progress is saved on the way out), then offer the list.
    func switchSource(for target: PlaybackTarget) {
        closePlayer { [weak self] in self?.chooseSource(for: target) }
    }

    /// Up Next: close this episode and start the next with the same kind of release.
    func playNext(_ target: PlaybackTarget, after current: PlayerSession, settings: AppSettings, library: Library) {
        closePlayer { [weak self] in
            self?.play(target, settings: settings, library: library, fromStart: true, automatic: true,
                       preferGroup: current.source.bingeGroup)
        }
    }

    func cancel() {
        work?.cancel()
        work = nil
        preparing = nil
        fallbackNotice = nil
    }
}

enum PlaybackError: LocalizedError {
    case noSources(any: Bool)

    var errorDescription: String? {
        switch self {
        case .noSources(any: true): return "Releases were found, but none can stream right now. Try the Sources list or relax the filters in Settings."
        case .noSources(any: false): return "No releases were found for this title yet."
        }
    }

    /// What to tell the user, with the network named when it is the cause, and no key in sight.
    static func describe(_ error: Error) -> String {
        if HTTP.isOffline(error) { return "You seem to be offline. Check your connection and try again." }
        return Redact.text(error.localizedDescription)
    }
}
