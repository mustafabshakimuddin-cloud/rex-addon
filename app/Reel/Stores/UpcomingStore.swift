import Foundation
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
final class UpcomingStore: ObservableObject {
    @Published private(set) var episodes: [CalendarEpisode] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var loadedAt: Date?

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

    /// Aired in the last two weeks and not watched yet: what Home calls New Episodes.
    func newEpisodes(_ library: Library) -> [CalendarEpisode] {
        let cutoff = Date().addingTimeInterval(-Self.newWindow)
        var seen = Set<String>()
        // Newest first, one per series: the latest episode stands for the rest.
        return episodes.reversed().filter { entry in
            entry.hasAired && entry.date > cutoff && !library.isWatched(entry.target) && seen.insert(entry.item.id).inserted
        }
    }

    var upcoming: [CalendarEpisode] { episodes.filter { !$0.hasAired } }
    var recent: [CalendarEpisode] { episodes.filter(\.hasAired).reversed() }

    var airingToday: [CalendarEpisode] {
        episodes.filter { Calendar.current.isDateInToday($0.date) }
    }
}
