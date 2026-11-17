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
        } else {
            watchlist.insert(item, at: 0)
        }
        scheduleSave()
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

    func isWatched(_ episode: Episode) -> Bool { progress[episode.id]?.isFinished ?? false }

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

    /// The episode to offer next: the one after the latest watched, or the first.
    func nextEpisode(in detail: MediaDetail) -> Episode? {
        let regular = detail.episodes.filter { $0.season > 0 }.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
        let latest = regular.lastIndex { progress[$0.id] != nil }
        guard let latest else { return regular.first }
        let current = regular[latest]
        if let entry = progress[current.id], !entry.isFinished { return current }
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
