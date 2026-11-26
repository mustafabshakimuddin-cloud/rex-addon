import Foundation
import Observation
import Combine

/// One episode on the calendar.
struct CalendarEpisode: Identifiable, Hashable {
    let item: MediaItem
    let episode: Episode
    let date: Date

    var id: String { episode.id }
    var target: PlaybackTarget { PlaybackTarget(item: item, episode: episode) }
    var hasAired: Bool { date <= Date() }
}

/// New and upcoming episodes of the series you follow: those in My List and those you have watched
/// lately. One Cinemeta request covers them all, and the answer is reused for half an hour.
@MainActor
@Observable
final class UpcomingStore {
    private(set) var episodes: [CalendarEpisode] = [] { didSet { newCache = nil } }
    /// New episodes by series, for one library revision: Home and the badge ask several times
    /// per redraw.
    @ObservationIgnored private var newCache: (revision: Int, value: [String: [CalendarEpisode]])?
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var loadedAt: Date?

    private var loadedFor: [String] = []
    private static let lifetime: TimeInterval = 30 * 60
    static let lookBack: TimeInterval = 30 * 86_400
    static let lookAhead: TimeInterval = 180 * 86_400
    /// How long an aired, unwatched episode counts as new.
    static let newWindow: TimeInterval = 14 * 86_400

    /// Series in My List first, then those watched in the last three months, newest first.
    static func followedSeries(_ library: Library) -> [MediaItem] {
        let recentCutoff = Date().addingTimeInterval(-90 * 86_400)
        var seen = Set<String>()
        let listed = library.watchlist.filter { $0.kind == .series }
        let watched = library.history.filter { $0.item.kind == .series && $0.updatedAt > recentCutoff }.map(\.item)
        return (listed + watched).filter { seen.insert($0.id).inserted }.prefix(80).map { $0 }
    }

    func refresh(_ library: Library, force: Bool = false) async {
        let followed = Self.followedSeries(library)
        let ids = followed.map(\.id)
        if !force, ids == loadedFor, let loadedAt, Date().timeIntervalSince(loadedAt) < Self.lifetime { return }
        guard !isLoading else { return }
        guard !ids.isEmpty else {
            episodes = []
            loadedFor = []
            loadedAt = Date()
            error = nil
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let details = try await Cinemeta.calendar(seriesIDs: ids)
            // Keep the library's own copy of each title: it has the artwork the lists showed.
            let known = Dictionary(followed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let now = Date()
            episodes = details.flatMap { detail -> [CalendarEpisode] in
                let item = known[detail.item.id] ?? detail.item
                return detail.episodes.compactMap { episode in
                    guard episode.season > 0, let date = episode.released,
                          date > now.addingTimeInterval(-Self.lookBack), date < now.addingTimeInterval(Self.lookAhead) else { return nil }
                    return CalendarEpisode(item: item, episode: episode, date: date)
                }
            }
            .sorted { ($0.date, $0.item.name, $0.episode.number) < ($1.date, $1.item.name, $1.episode.number) }
            loadedFor = ids
            loadedAt = Date()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Episodes aired in the last two weeks that come after the furthest one you have watched or
    /// started in that series, grouped by series, each in episode order. Marking an episode
    /// watched also settles every earlier one: you've moved past them.
    func unwatchedNew(_ library: Library) -> [String: [CalendarEpisode]] {
        if let newCache, newCache.revision == library.revision { return newCache.value }
        let value = computeUnwatchedNew(library)
        newCache = (library.revision, value)
        return value
    }

    private func computeUnwatchedNew(_ library: Library) -> [String: [CalendarEpisode]] {
        let cutoff = Date().addingTimeInterval(-Self.newWindow)
        let recent = episodes.filter { $0.hasAired && $0.date > cutoff }
        var bySeries: [String: [CalendarEpisode]] = [:]
        for (seriesID, entries) in Dictionary(grouping: recent, by: \.item.id) {
            let reached = library.furthestEpisode(inSeries: seriesID)
            let ahead = entries.filter { entry in
                let position = (entry.episode.season, entry.episode.number)
                if let reached, position <= reached { return false }
                return !library.isWatched(entry.target) && library.progress(for: entry.target) == nil
            }
            if !ahead.isEmpty {
                bySeries[seriesID] = ahead.sorted { ($0.episode.season, $0.episode.number) < ($1.episode.season, $1.episode.number) }
            }
        }
        return bySeries
    }

    /// One card per series: the next new episode to watch, most recently aired series first.
    func newEpisodes(_ library: Library) -> [CalendarEpisode] {
        // The latest aired date per series, once, rather than a scan per comparison.
        var latest: [String: Date] = [:]
        for entry in episodes where entry.hasAired { latest[entry.item.id] = max(latest[entry.item.id] ?? .distantPast, entry.date) }
        return unwatchedNew(library).values.compactMap(\.first).sorted { lhs, rhs in
            (latest[lhs.item.id] ?? lhs.date) > (latest[rhs.item.id] ?? rhs.date)
        }
    }

    /// How many new episodes are waiting across every series.
    func newEpisodeCount(_ library: Library) -> Int {
        unwatchedNew(library).values.reduce(0) { $0 + $1.count }
    }

    var upcoming: [CalendarEpisode] { episodes.filter { !$0.hasAired } }
    var recent: [CalendarEpisode] { episodes.filter(\.hasAired).reversed() }

    var airingToday: [CalendarEpisode] {
        episodes.filter { Calendar.current.isDateInToday($0.date) }
    }
}
