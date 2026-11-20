import Foundation
import Combine

struct PlaybackProgress: Codable, Hashable, Identifiable {
    var item: MediaItem
    var episode: Episode?
    var position: Double
    var duration: Double
    var updatedAt: Date

    var id: String { episode?.id ?? item.id }
    var fraction: Double { duration > 0 ? min(1, max(0, position / duration)) : 0 }
    var isFinished: Bool { fraction >= Library.finishedFraction }
    var target: PlaybackTarget { PlaybackTarget(item: item, episode: episode) }
}

/// Watchlist and playback positions, kept in a JSON file in Application Support.
@MainActor
final class Library: ObservableObject {
    nonisolated static let finishedFraction = 0.92
    nonisolated static let minimumResume: Double = 30
    /// Positions kept on disk; the oldest go first. Every episode ever opened would otherwise stay
    /// forever, and the whole file is rewritten on each save.
    nonisolated static let maximumEntries = 1500

    @Published private(set) var watchlist: [MediaItem] = []
    @Published private(set) var progress: [String: PlaybackProgress] = [:]
    /// Watched on another device, as Trakt reports it: film IMDb ids and episode video ids.
    @Published private(set) var externalWatched: Set<String> = []

    /// Told about each watchlist change the user makes here, so Trakt can follow.
    var onWatchlistChange: ((MediaItem, Bool) -> Void)?

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init() {
        let folder = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        fileURL = folder.appendingPathComponent("library.json")
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            watchlist = saved.watchlist
            progress = saved.progress
        }
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

    /// Adds what Trakt's watchlist has and this one lacks. Nothing is removed: a title taken off
    /// here is taken off Trakt as it happens, so a difference left over is one Trakt added.
    func mergeWatchlist(_ items: [MediaItem]) {
        let known = Set(watchlist.map(\.id))
        let added = items.filter { !known.contains($0.id) }
        guard !added.isEmpty else { return }
        watchlist.append(contentsOf: added)
        scheduleSave()
    }

    /// A resume point from another device, kept only when it is newer than the one here.
    func importResume(_ target: PlaybackTarget, fraction: Double, runtime: Double, at date: Date) {
        if let existing = progress[target.videoID], existing.updatedAt >= date { return }
        let duration = max(runtime, 60)
        var item = target.item
        if let existing = progress[target.videoID] { item = existing.item }
        progress[target.videoID] = PlaybackProgress(item: item, episode: target.episode, position: duration * fraction,
                                                    duration: duration, updatedAt: date)
        scheduleSave(after: 2)
    }

    func setExternalWatched(movies: Set<String>, episodes: Set<String>) {
        externalWatched = movies.union(episodes)
    }

    // MARK: Progress

    /// The newest unfinished entry per title, most recent first.
    var continueWatching: [PlaybackProgress] {
        var seen = Set<String>()
        return progress.values
            .filter { !$0.isFinished && $0.position >= Self.minimumResume }
            .sorted { $0.updatedAt > $1.updatedAt }
            .filter { seen.insert($0.item.id).inserted }
    }

    func progress(for target: PlaybackTarget) -> PlaybackProgress? { progress[target.videoID] }

    func resumePosition(for target: PlaybackTarget) -> Double? {
        guard let entry = progress[target.videoID], !entry.isFinished, entry.position >= Self.minimumResume else { return nil }
        return entry.position
    }

    func isWatched(_ episode: Episode) -> Bool { progress[episode.id]?.isFinished ?? externalWatched.contains(episode.id) }

    func isWatched(_ target: PlaybackTarget) -> Bool { progress[target.videoID]?.isFinished ?? externalWatched.contains(target.videoID) }

    func record(_ target: PlaybackTarget, position: Double, duration: Double) {
        guard duration > 0, position.isFinite, duration.isFinite else { return }
        progress[target.videoID] = PlaybackProgress(item: target.item, episode: target.episode, position: position, duration: duration, updatedAt: Date())
        if progress.count > Self.maximumEntries {
            let overflow = progress.values.sorted { $0.updatedAt < $1.updatedAt }.prefix(progress.count - Self.maximumEntries)
            for entry in overflow { progress[entry.id] = nil }
        }
        // While playing, positions arrive every 10 s; the file only needs the last of a burst.
        // The player and the app's background transition both call saveNow() on the way out.
        scheduleSave(after: 5)
    }

    func clearProgress(_ entry: PlaybackProgress) {
        progress[entry.id] = nil
        scheduleSave()
    }

    /// Everything opened, most recent first: the History screen's timeline.
    var history: [PlaybackProgress] {
        progress.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    func clearHistory() {
        progress = [:]
        scheduleSave()
    }

    /// Marks a film or episode as seen without playing it. Kept on this device; Trakt learns of
    /// watches through the scrobbles sent while playing.
    func markWatched(_ target: PlaybackTarget) {
        let duration = max(progress[target.videoID]?.duration ?? 0, 60)
        progress[target.videoID] = PlaybackProgress(item: target.item, episode: target.episode, position: duration,
                                                    duration: duration, updatedAt: Date())
        scheduleSave()
    }

    func markUnwatched(_ target: PlaybackTarget) {
        progress[target.videoID] = nil
        externalWatched.remove(target.videoID)
        scheduleSave()
    }

    func markWatched(_ episodes: [Episode], of item: MediaItem) {
        let now = Date()
        for (offset, episode) in episodes.filter(\.hasAired).enumerated() {
            let duration = max(progress[episode.id]?.duration ?? 0, 60)
            // A second apart, so the latest episode is also the most recent in History.
            progress[episode.id] = PlaybackProgress(item: item, episode: episode, position: duration, duration: duration,
                                                    updatedAt: now.addingTimeInterval(Double(offset) - Double(episodes.count)))
        }
        scheduleSave()
    }

    func markUnwatched(_ episodes: [Episode]) {
        for episode in episodes {
            progress[episode.id] = nil
            externalWatched.remove(episode.id)
        }
        scheduleSave()
    }

    /// The furthest regular episode of a series you've finished or started here, or that Trakt
    /// says you watched, as (season, episode).
    func furthestEpisode(inSeries seriesID: String) -> (Int, Int)? {
        var furthest: (Int, Int)?
        func consider(_ position: (Int, Int)) {
            guard position.0 > 0 else { return }  // specials don't move you along
            if furthest.map({ position > $0 }) ?? true { furthest = position }
        }
        for entry in progress.values where entry.item.id == seriesID {
            if let episode = entry.episode { consider((episode.season, episode.number)) }
        }
        let prefix = seriesID + ":"
        for id in externalWatched where id.hasPrefix(prefix) {
            let parts = id.dropFirst(prefix.count).split(separator: ":")
            if parts.count == 2, let season = Int(parts[0]), let number = Int(parts[1]) { consider((season, number)) }
        }
        return furthest
    }

    /// The episode to offer next: the one after the latest watched, or the first.
    func nextEpisode(in detail: MediaDetail) -> Episode? {
        let regular = detail.episodes.filter { $0.season > 0 }.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
        let latest = regular.lastIndex { progress[$0.id] != nil || externalWatched.contains($0.id) }
        guard let latest else { return regular.first }
        let current = regular[latest]
        if let entry = progress[current.id], !entry.isFinished, !externalWatched.contains(current.id) { return current }
        return regular.indices.contains(latest + 1) ? regular[latest + 1] : current
    }

    // MARK: Persistence

    private struct Saved: Codable {
        var watchlist: [MediaItem]
        var progress: [String: PlaybackProgress]
    }

    private func scheduleSave(after seconds: Double = 0.4) {
        saveTask?.cancel()
        let snapshot = Saved(watchlist: watchlist, progress: progress)
        let url = fileURL
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    func saveNow() {
        saveTask?.cancel()
        if let data = try? JSONEncoder().encode(Saved(watchlist: watchlist, progress: progress)) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
