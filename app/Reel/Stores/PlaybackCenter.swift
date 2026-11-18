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
    private var sourceCache: [String: CachedSources] = [:]
    private var resolvedCache: [String: (url: URL, at: Date)] = [:]
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
        if !refresh, let cached = sourceCache[target.videoID], cached.query == query,
           Date().timeIntervalSince(cached.at) < Self.sourceLifetime {
            return cached.sources
        }
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

    /// The final address of a source, reused for half an hour: a debrid link stays valid far
    /// longer than that, and resolving twice adds the same torrent to the account twice.
    func resolve(_ source: StreamSource) async throws -> URL {
        if let hit = resolvedCache[source.fileKey], Date().timeIntervalSince(hit.at) < Self.resolvedLifetime {
            return hit.url
        }
        let url = try await Torrentio.resolve(source)
        resolvedCache[source.fileKey] = (url, Date())
        return url
    }

    /// Called by a title page: look up its sources now so Play and the source list don't wait.
    /// With "Get streams ready" on, also resolve the likely pick and fetch its first bytes.
    func prefetch(_ target: PlaybackTarget, settings: AppSettings) {
        guard settings.canFindSources else { return }
        let query = settings.sourceQuery
        let prepare = settings.prepareAhead
        Task { [weak self] in
            guard let self, let all = try? await self.sources(for: target, query: query) else { return }
            guard prepare, let top = SourceRanker.rank(all, memory: self.memory).first(where: \.isCached),
                  let url = try? await self.resolve(top) else { return }
            await Task.detached(priority: .utility) { _ = await AetherEngine.prewarm(url: url) }.value
        }
    }

    /// Opens the file and reads its real format, then remembers the answer for the source list.
    func verify(_ source: StreamSource) async throws -> SourceVerification {
        let url = try await resolve(source)
        let verification = try await SourceVerifier.verify(url: url)
        memory.store(verification, for: source)
        return verification
    }

    // MARK: Downloading

    /// Saves a title for offline viewing: the source given, or the one Play would have picked.
    func download(_ target: PlaybackTarget, settings: AppSettings, source: StreamSource? = nil) {
        guard settings.canFindSources else {
            needsDebridSetup = true
            return
        }
        let query = settings.sourceQuery
        Task { [weak self] in
            guard let self else { return }
            do {
                let candidates: [StreamSource]
                if let source {
                    candidates = [source]
                } else {
                    let all = try await self.sources(for: target, query: query)
                    candidates = SourceRanker.rank(all, memory: self.memory).filter(\.isCached)
                }
                var lastError: Error = PlaybackError.noSources(any: true)
                for candidate in candidates.prefix(3) {
                    do {
                        let url = try await self.resolve(candidate)
                        self.downloads.start(target, source: candidate, url: url)
                        return
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

    // MARK: Playing

    func play(_ target: PlaybackTarget, settings: AppSettings, library: Library, source: StreamSource? = nil,
              fromStart: Bool = false, automatic: Bool = false, preferGroup: String? = nil) {
        let startAt = fromStart ? nil : library.resumePosition(for: target)
        // A finished download plays from the device, with no network and no debrid service.
        if source == nil, let local = downloads.completedFile(for: target) {
            errorMessage = nil
            session = PlayerSession(target: target, url: local.url, source: local.source, startAt: startAt, isLocal: true)
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
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let candidates: [StreamSource]
                if let source {
                    candidates = [source]
                } else {
                    let all = try await self.sources(for: target, query: query)
                    candidates = SourceRanker.rank(all, memory: self.memory, preferGroup: preferGroup)
                    guard !candidates.isEmpty else { throw PlaybackError.noSources(any: !all.isEmpty) }
                }
                try await self.open(target, candidates: candidates, startAt: startAt,
                                    attempts: source == nil ? Self.maxAttempts : 1, keepAlternates: source == nil)
            } catch is CancellationError {
                self.preparing = nil
            } catch {
                self.preparing = nil
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Resolves candidates in order until one gives an address, then presents the player with the
    /// rest kept as alternates.
    private func open(_ target: PlaybackTarget, candidates: [StreamSource], startAt: Double?,
                      attempts: Int, keepAlternates: Bool) async throws {
        var lastError: Error?
        for (index, candidate) in candidates.prefix(attempts).enumerated() {
            try Task.checkCancellation()
            do {
                let url = try await resolve(candidate)
                try Task.checkCancellation()
                preparing = nil
                let rest = keepAlternates ? Array(candidates.dropFirst(index + 1).prefix(4)) : []
                session = PlayerSession(target: target, url: url, source: candidate, startAt: startAt, alternates: rest)
                return
            } catch let error as ResolveError where error == .accessDenied {
                throw error  // every source will fail the same way
            } catch is CancellationError {
                throw CancellationError()
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

    /// The player could not open its source. Remember that, and when the source was picked
    /// automatically, quietly move on to the next one. Returns whether a replacement is coming.
    @discardableResult
    func playerFailed(_ failed: PlayerSession, reason: String, position: Double?) -> Bool {
        guard !failed.isLocal else { return false }
        memory.noteFailure(failed.source, reason: reason)
        resolvedCache[failed.source.fileKey] = nil
        guard !failed.alternates.isEmpty else { return false }
        fallbackNotice = "That source didn't open. Trying the next one…"
        let startAt = position.flatMap { $0 > 5 ? $0 : nil } ?? failed.startAt
        work?.cancel()
        work = Task { [weak self] in
            guard let self else { return }
            self.session = nil
            self.preparing = failed.target
            try? await Task.sleep(nanoseconds: 650_000_000)  // let the full-screen cover finish closing
            do {
                try await self.open(failed.target, candidates: failed.alternates, startAt: startAt,
                                    attempts: Self.maxAttempts, keepAlternates: true)
            } catch is CancellationError {
                self.preparing = nil
            } catch {
                self.preparing = nil
                self.errorMessage = error.localizedDescription
            }
            self.fallbackNotice = nil
        }
        return true
    }

    func chooseSource(for target: PlaybackTarget, fromStart: Bool = false) {
        chooseFromStart = fromStart
        choosingSource = target
    }

    /// From the player: close it (its progress is saved on the way out), then offer the list.
    func switchSource(for target: PlaybackTarget) {
        session = nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 650_000_000)  // let the full-screen cover finish closing
            self.chooseSource(for: target)
        }
    }

    /// Up Next: close this episode and start the next with the same kind of release.
    func playNext(_ target: PlaybackTarget, after current: PlayerSession, settings: AppSettings, library: Library) {
        session = nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 650_000_000)
            self.play(target, settings: settings, library: library, fromStart: true, automatic: true,
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
        case .noSources(any: true): return "Releases were found, but none your debrid service can stream right now. Try the Sources list or relax the filters in Settings."
        case .noSources(any: false): return "No releases were found for this title yet."
        }
    }
}
