import Foundation
import Combine

struct PlaybackProgress: Codable, Hashable, Identifiable {
    var item: MediaItem
    var episode: Episode?
    var position: Double
    var duration: Double
    var updatedAt: Date
    /// Marked as watched by hand rather than played: its duration is a stand-in.
    var marked: Bool?
    /// Not played yet: the episode after the last one you finished, offered in Continue Watching.
    var upNext: Bool?

    var id: String { episode?.id ?? item.id }
    var fraction: Double { duration > 0 ? min(1, max(0, position / duration)) : 0 }
    var isFinished: Bool { fraction >= Library.finishedFraction }
    var isUpNext: Bool { upNext == true }
    var target: PlaybackTarget { PlaybackTarget(item: item, episode: episode) }
}

/// Watchlist and playback positions, kept in a JSON file in Application Support.
///
/// Changes publish once per user action. Positions recorded while the player is open are kept
/// without publishing, so the screens behind the player don't redraw every ten seconds; they are
/// published when the player closes (`commitLive`).
@MainActor
final class Library: ObservableObject {
    nonisolated static let finishedFraction = 0.92
    nonisolated static let minimumResume: Double = 30
    /// Positions kept on disk; the oldest go first. Every episode ever opened would otherwise stay
    /// forever, and the whole file is rewritten on each save.
    nonisolated static let maximumEntries = 1500
    private static let fileVersion = 2

    @Published private(set) var watchlist: [MediaItem] = [] { didSet { revision += 1 } }
    private(set) var progress: [String: PlaybackProgress] = [:] { didSet { revision += 1 } }
    /// Watched on another device, as Trakt reports it: film IMDb ids and episode video ids, less
    /// those you marked unwatched here since.
    private(set) var externalWatched: Set<String> = [] { didSet { revision += 1 } }
    /// Ids marked unwatched here while Trakt still listed them as watched, with when.
    private var unwatchedOverrides: [String: Date] = [:]
    /// What Trakt's watchlist held at the last sync, to tell its removals from additions here.
    private var traktWatchlist: Set<String>?
    /// Next episodes for Continue Watching, by series id.
    private var upNext: [String: PlaybackProgress] = [:] { didSet { revision += 1 } }
    /// Next episodes dismissed from Continue Watching, by series id; they don't come back.
    private var dismissedUpNext: [String: String] = [:]
    /// Each series' aired regular episodes in order, learned from title pages and the player.
    private var knownEpisodes: [String: [Episode]] = [:]
    private var rawExternalWatched: Set<String> = []

    /// Bumped on every change; derived lists are cached against it.
    private(set) var revision = 0

    /// Told about each watchlist change the user makes here, so Trakt can follow.
    var onWatchlistChange: ((MediaItem, Bool) -> Void)?
    /// Told when titles are marked watched (true) or unwatched (false) by hand.
    var onWatchedChange: (([PlaybackTarget], Bool) -> Void)?

    private var fileURL: URL
    private var writer: SnapshotWriter
    /// Only family and animation titles in lists and rows: a kids profile.
    @Published var kidsOnly = false
    private var cache = Cache()

    private struct Cache {
        var revision = -1
        var history: [PlaybackProgress]?
        var continueWatching: [PlaybackProgress]?
        var furthest: [String: (Int, Int)]?
    }

    init(fileURL: URL = JSONFile.url("library.json")) {
        self.fileURL = fileURL
        writer = SnapshotWriter(url: fileURL)
        if let saved = JSONFile.read(Saved.self, from: fileURL) { apply(saved) }
    }

    /// Switches to another profile's library: what was here is saved first.
    func load(from fileURL: URL) {
        // The outgoing profile's file must be on disk before anything reads it again.
        saveNow()
        writer.waitUntilWritten()
        objectWillChange.send()
        self.fileURL = fileURL
        writer = SnapshotWriter(url: fileURL)
        knownEpisodes = [:]
        apply(JSONFile.read(Saved.self, from: fileURL) ?? Saved(version: Self.fileVersion, watchlist: [], progress: [:], externalWatched: [],
                                                               unwatchedOverrides: [:], traktWatchlist: nil, upNext: [:], dismissedUpNext: [:]))
    }

    private func apply(_ saved: Saved) {
        watchlist = saved.watchlist
        progress = saved.progress
        rawExternalWatched = saved.externalWatched
        unwatchedOverrides = saved.unwatchedOverrides
        traktWatchlist = saved.traktWatchlist
        upNext = saved.upNext
        dismissedUpNext = saved.dismissedUpNext
        externalWatched = rawExternalWatched.subtracting(unwatchedOverrides.keys)
    }

    // MARK: Watchlist

    func isInWatchlist(_ item: MediaItem) -> Bool { watchlist.contains { $0.id == item.id } }

    func toggleWatchlist(_ item: MediaItem) {
        if let index = watchlist.firstIndex(where: { $0.id == item.id }) {
            watchlist.remove(at: index)
            onWatchlistChange?(item, false)
        } else {
            watchlist.insert(item, at: 0)
            onWatchlistChange?(item, true)
        }
        scheduleSave()
    }

    /// Brings the watchlist in line with Trakt's. Titles Trakt has and this one lacks are added;
    /// titles Trakt had at the last sync and no longer has were removed elsewhere, so they go here
    /// too. Changes made here and not yet sent to Trakt are left alone.
    func applyTraktWatchlist(_ items: [MediaItem], pendingAdds: Set<String> = [], pendingRemovals: Set<String> = []) {
        let remote = Set(items.map(\.id))
        var changed = false
        if let previous = traktWatchlist {
            let removedElsewhere = previous.subtracting(remote).subtracting(pendingAdds)
            if !removedElsewhere.isEmpty {
                let before = watchlist.count
                watchlist.removeAll { removedElsewhere.contains($0.id) }
                changed = changed || watchlist.count != before
            }
        }
        let known = Set(watchlist.map(\.id))
        let added = items.filter { !known.contains($0.id) && !pendingRemovals.contains($0.id) }
        if !added.isEmpty {
            watchlist.append(contentsOf: added)
            changed = true
        }
        if traktWatchlist != remote { traktWatchlist = remote; changed = true }
        if changed { scheduleSave() }
    }

    /// A resume point from another device, kept only when it is newer than the one here.
    func importResume(_ target: PlaybackTarget, fraction: Double, runtime: Double, at date: Date) {
        if let existing = progress[target.videoID], existing.updatedAt >= date { return }
        let duration = max(runtime, 60)
        var item = target.item
        if let existing = progress[target.videoID] { item = existing.item }
        progress[target.videoID] = PlaybackProgress(item: item, episode: target.episode, position: duration * fraction,
                                                    duration: duration, updatedAt: date)
        objectWillChange.send()
        scheduleSave(after: 2)
    }

    /// Trakt's watched history. An id marked unwatched here stays unwatched while Trakt still
    /// lists it (the removal may not have reached Trakt yet); once Trakt agrees, the override goes.
    func setExternalWatched(movies: Set<String>, episodes: Set<String>) {
        let all = movies.union(episodes)
        unwatchedOverrides = unwatchedOverrides.filter { all.contains($0.key) }
        guard all != rawExternalWatched || externalWatched != all.subtracting(unwatchedOverrides.keys) else { return }
        rawExternalWatched = all
        objectWillChange.send()
        externalWatched = all.subtracting(unwatchedOverrides.keys)
        refreshAllUpNext()
        scheduleSave(after: 2)
    }

    /// Forgets Trakt's state, when Trakt is disconnected.
    func forgetTraktState() {
        objectWillChange.send()
        rawExternalWatched = []
        externalWatched = []
        unwatchedOverrides = [:]
        traktWatchlist = nil
        scheduleSave()
    }

    // MARK: Progress

    /// The newest unfinished entry per title, most recent first, with the next episode of series
    /// whose latest episode you finished.
    var continueWatching: [PlaybackProgress] {
        refreshCache()
        if let cached = cache.continueWatching { return cached }
        var seen = Set<String>()
        let started = progress.values.filter { !$0.isFinished && $0.position >= Self.minimumResume }
        let next = upNext.values.filter { entry in
            guard let episode = entry.episode else { return false }
            return progress[episode.id] == nil && !externalWatched.contains(episode.id)
        }
        let list = (started + next)
            .sorted { $0.updatedAt > $1.updatedAt }
            .filter { seen.insert($0.item.id).inserted }
        cache.continueWatching = list
        return list
    }

    func progress(for target: PlaybackTarget) -> PlaybackProgress? { progress[target.videoID] }

    func resumePosition(for target: PlaybackTarget) -> Double? {
        guard let entry = progress[target.videoID], !entry.isFinished, entry.position >= Self.minimumResume else { return nil }
        return entry.position
    }

    func isWatched(_ episode: Episode) -> Bool { progress[episode.id]?.isFinished ?? externalWatched.contains(episode.id) }

    func isWatched(_ target: PlaybackTarget) -> Bool { progress[target.videoID]?.isFinished ?? externalWatched.contains(target.videoID) }

    /// A position from the player. With `live`, nothing is published until `commitLive()`.
    func record(_ target: PlaybackTarget, position: Double, duration: Double, live: Bool = false) {
        guard duration > 0, position.isFinite, duration.isFinite else { return }
        let wasFinished = progress[target.videoID]?.isFinished ?? false
        progress[target.videoID] = PlaybackProgress(item: target.item, episode: target.episode, position: position, duration: duration, updatedAt: Date())
        trimOverflow()
        let entry = progress[target.videoID]
        if entry?.isFinished == true, !wasFinished { refreshUpNext(seriesID: target.item.id, item: target.item) }
        if !live { objectWillChange.send() }
        // While playing, positions arrive every 10 s; the file only needs the last of a burst.
        // The player and the app's background transition both call saveNow() on the way out.
        scheduleSave(after: 5)
    }

    /// Publishes the positions recorded while the player was open.
    func commitLive() {
        objectWillChange.send()
        saveNow()
    }

    func clearProgress(_ entry: PlaybackProgress) {
        objectWillChange.send()
        if entry.isUpNext, let episode = entry.episode {
            upNext[entry.item.id] = nil
            dismissedUpNext[entry.item.id] = episode.id
        } else {
            progress[entry.id] = nil
        }
        scheduleSave()
    }

    /// Everything opened, most recent first: the History screen's timeline.
    var history: [PlaybackProgress] {
        refreshCache()
        if let cached = cache.history { return cached }
        let list = progress.values.sorted { $0.updatedAt > $1.updatedAt }
        cache.history = list
        return list
    }

    func clearHistory() {
        objectWillChange.send()
        progress = [:]
        upNext = [:]
        scheduleSave()
    }

    /// Marks a film or episode as seen without playing it.
    func markWatched(_ target: PlaybackTarget) {
        objectWillChange.send()
        let duration = max(progress[target.videoID]?.duration ?? 0, 60)
        progress[target.videoID] = PlaybackProgress(item: target.item, episode: target.episode, position: duration,
                                                    duration: duration, updatedAt: Date(), marked: true)
        unwatchedOverrides[target.videoID] = nil
        externalWatched = rawExternalWatched.subtracting(unwatchedOverrides.keys)
        refreshUpNext(seriesID: target.item.id, item: target.item)
        onWatchedChange?([target], true)
        scheduleSave()
    }

    func markUnwatched(_ target: PlaybackTarget) {
        markUnwatched([target])
    }

    func markWatched(_ episodes: [Episode], of item: MediaItem) {
        objectWillChange.send()
        let now = Date()
        let aired = episodes.filter(\.hasAired)
        for (offset, episode) in aired.enumerated() {
            let duration = max(progress[episode.id]?.duration ?? 0, 60)
            // A second apart, so the latest episode is also the most recent in History.
            progress[episode.id] = PlaybackProgress(item: item, episode: episode, position: duration, duration: duration,
                                                    updatedAt: now.addingTimeInterval(Double(offset) - Double(aired.count)),
                                                    marked: true)
            unwatchedOverrides[episode.id] = nil
        }
        externalWatched = rawExternalWatched.subtracting(unwatchedOverrides.keys)
        refreshUpNext(seriesID: item.id, item: item)
        onWatchedChange?(aired.map { PlaybackTarget(item: item, episode: $0) }, true)
        scheduleSave()
    }

    func markUnwatched(_ episodes: [Episode], of item: MediaItem) {
        markUnwatched(episodes.map { PlaybackTarget(item: item, episode: $0) })
    }

    private func markUnwatched(_ targets: [PlaybackTarget]) {
        guard !targets.isEmpty else { return }
        objectWillChange.send()
        let now = Date()
        for target in targets {
            progress[target.videoID] = nil
            if rawExternalWatched.contains(target.videoID) { unwatchedOverrides[target.videoID] = now }
        }
        externalWatched = rawExternalWatched.subtracting(unwatchedOverrides.keys)
        for seriesID in Set(targets.filter { $0.episode != nil }.map(\.item.id)) {
            if let item = targets.first(where: { $0.item.id == seriesID })?.item { refreshUpNext(seriesID: seriesID, item: item) }
        }
        onWatchedChange?(targets, false)
        scheduleSave()
    }

    /// The furthest regular episode of a series you've finished or started here, or that Trakt
    /// says you watched, as (season, episode).
    func furthestEpisode(inSeries seriesID: String) -> (Int, Int)? {
        refreshCache()
        if let furthest = cache.furthest { return furthest[seriesID] }
        // One pass over everything, for every series at once: New Episodes asks for each series.
        var furthest: [String: (Int, Int)] = [:]
        func consider(_ series: String, _ position: (Int, Int)) {
            guard position.0 > 0 else { return }  // specials don't move you along
            if furthest[series].map({ position > $0 }) ?? true { furthest[series] = position }
        }
        for entry in progress.values {
            if let episode = entry.episode { consider(entry.item.id, (episode.season, episode.number)) }
        }
        for id in externalWatched {
            let parts = id.split(separator: ":")
            if parts.count == 3, let season = Int(parts[1]), let number = Int(parts[2]) { consider(String(parts[0]), (season, number)) }
        }
        cache.furthest = furthest
        return furthest[seriesID]
    }

    /// The episode to offer next: the one after the latest watched, or the first. Episodes that
    /// haven't aired are never offered; nil means you're caught up (or nothing has aired).
    func nextEpisode(in detail: MediaDetail) -> Episode? {
        let regular = detail.episodes.filter { $0.season > 0 }.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
        let latest = regular.lastIndex { progress[$0.id] != nil || externalWatched.contains($0.id) }
        guard let latest else { return regular.first(where: \.hasAired) }
        let current = regular[latest]
        if let entry = progress[current.id], !entry.isFinished, !externalWatched.contains(current.id), current.hasAired { return current }
        guard regular.indices.contains(latest + 1) else { return nil }
        let next = regular[latest + 1]
        return next.hasAired ? next : nil
    }

    /// The next episode still to air after the ones you've watched, when you're caught up.
    func caughtUp(in detail: MediaDetail) -> (caughtUp: Bool, nextAiring: Episode?) {
        let regular = detail.episodes.filter { $0.season > 0 }.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
        guard regular.contains(where: { progress[$0.id] != nil || externalWatched.contains($0.id) }),
              nextEpisode(in: detail) == nil else { return (false, nil) }
        return (true, regular.first { !$0.hasAired })
    }

    // MARK: Up next

    /// Remembers a series' episodes (from its title page or the player), so the episode after the
    /// one you finish can wait for you in Continue Watching.
    func learnEpisodes(_ detail: MediaDetail) {
        guard detail.item.kind == .series else { return }
        let regular = detail.episodes.filter { $0.season > 0 }.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
        guard knownEpisodes[detail.item.id] != regular else { return }
        knownEpisodes[detail.item.id] = regular
        let item = progress.values.first { $0.item.id == detail.item.id }?.item ?? detail.item
        let before = upNext[detail.item.id]
        refreshUpNext(seriesID: detail.item.id, item: item)
        if upNext[detail.item.id] != before {
            objectWillChange.send()
            scheduleSave()
        }
    }

    private func refreshAllUpNext() {
        for (seriesID, _) in knownEpisodes {
            if let item = upNext[seriesID]?.item ?? progress.values.first(where: { $0.item.id == seriesID })?.item {
                refreshUpNext(seriesID: seriesID, item: item)
            }
        }
    }

    private func refreshUpNext(seriesID: String, item: MediaItem) {
        guard item.kind == .series, let episodes = knownEpisodes[seriesID] else { return }
        let detail = MediaDetail(item: item, episodes: episodes)
        let entries = episodes.compactMap { progress[$0.id] }
        guard let next = nextEpisode(in: detail),
              progress[next.id] == nil,
              dismissedUpNext[seriesID] != next.id else {
            if upNext[seriesID] != nil { upNext[seriesID] = nil }
            return
        }
        // Only once a previous episode was finished: an episode merely started shows itself.
        guard let index = episodes.firstIndex(where: { $0.id == next.id }), index > 0 else {
            if upNext[seriesID] != nil { upNext[seriesID] = nil }
            return
        }
        let finishedAt = entries.map(\.updatedAt).max() ?? Date()
        let entry = PlaybackProgress(item: item, episode: next, position: 0, duration: 0, updatedAt: finishedAt, upNext: true)
        if upNext[seriesID] != entry { upNext[seriesID] = entry }
    }

    // MARK: Persistence

    private struct Saved: Codable {
        var version: Int
        var watchlist: [MediaItem]
        var progress: [String: PlaybackProgress]
        var externalWatched: Set<String>
        var unwatchedOverrides: [String: Date]
        var traktWatchlist: Set<String>?
        var upNext: [String: PlaybackProgress]
        var dismissedUpNext: [String: String]

        init(version: Int, watchlist: [MediaItem], progress: [String: PlaybackProgress], externalWatched: Set<String>,
             unwatchedOverrides: [String: Date], traktWatchlist: Set<String>?, upNext: [String: PlaybackProgress],
             dismissedUpNext: [String: String]) {
            self.version = version
            self.watchlist = watchlist
            self.progress = progress
            self.externalWatched = externalWatched
            self.unwatchedOverrides = unwatchedOverrides
            self.traktWatchlist = traktWatchlist
            self.upNext = upNext
            self.dismissedUpNext = dismissedUpNext
        }

        /// Older files lack the newer fields, and one malformed entry only costs that entry.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
            watchlist = c.lossyArray(MediaItem.self, forKey: .watchlist)
            progress = c.lossyDictionary(PlaybackProgress.self, forKey: .progress)
            externalWatched = ((try? c.decodeIfPresent(Set<String>.self, forKey: .externalWatched)) ?? nil) ?? []
            unwatchedOverrides = ((try? c.decodeIfPresent([String: Date].self, forKey: .unwatchedOverrides)) ?? nil) ?? [:]
            traktWatchlist = (try? c.decodeIfPresent(Set<String>.self, forKey: .traktWatchlist)) ?? nil
            upNext = c.lossyDictionary(PlaybackProgress.self, forKey: .upNext)
            dismissedUpNext = ((try? c.decodeIfPresent([String: String].self, forKey: .dismissedUpNext)) ?? nil) ?? [:]
            // A file that has neither list isn't a library at all: refuse it so it is kept aside.
            guard c.contains(.watchlist) || c.contains(.progress) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Not a library file"))
            }
        }
    }

    private var snapshot: Saved {
        Saved(version: Self.fileVersion, watchlist: watchlist, progress: progress, externalWatched: rawExternalWatched,
              unwatchedOverrides: unwatchedOverrides, traktWatchlist: traktWatchlist, upNext: upNext,
              dismissedUpNext: dismissedUpNext)
    }

    private func trimOverflow() {
        guard progress.count > Self.maximumEntries else { return }
        let overflow = progress.values.sorted { $0.updatedAt < $1.updatedAt }.prefix(progress.count - Self.maximumEntries)
        for entry in overflow { progress[entry.id] = nil }
    }

    private func refreshCache() {
        if cache.revision != revision { cache = Cache(revision: revision) }
    }

    private func scheduleSave(after seconds: Double = 0.4) {
        let snapshot = snapshot
        writer.schedule(after: seconds) { try? JSONEncoder().encode(snapshot) }
    }

    func saveNow() {
        let snapshot = snapshot
        writer.flush { try? JSONEncoder().encode(snapshot) }
    }

    /// For tests: wait for queued writes to reach the disk.
    func waitForSave() { writer.waitUntilWritten() }

    // MARK: Backup

    /// The library as a file, for Settings → Back Up.
    func exportData() -> Data? { try? JSONEncoder().encode(snapshot) }

    /// Replaces the library with a backup's. Throws when the data isn't a library.
    func importData(_ data: Data) throws {
        let saved = try JSONDecoder().decode(Saved.self, from: data)
        objectWillChange.send()
        watchlist = saved.watchlist
        progress = saved.progress
        rawExternalWatched = saved.externalWatched
        unwatchedOverrides = saved.unwatchedOverrides
        traktWatchlist = saved.traktWatchlist
        upNext = saved.upNext
        dismissedUpNext = saved.dismissedUpNext
        externalWatched = rawExternalWatched.subtracting(unwatchedOverrides.keys)
        saveNow()
    }
}

extension Library {
    /// The titles a list shows: all of them, or with films you've watched left out.
    func shown(_ items: [MediaItem], hidingWatched: Bool) -> [MediaItem] {
        var items = items
        // A kids profile sees family and animation titles only.
        if kidsOnly { items = items.filter { $0.genres.contains("Family") || $0.genres.contains("Animation") } }
        guard hidingWatched else { return items }
        return items.filter { $0.kind != .movie || !isWatched(PlaybackTarget(item: $0)) }
    }
}
