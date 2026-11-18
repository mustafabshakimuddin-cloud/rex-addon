import Foundation

enum MediaKind: String, Codable, Hashable, CaseIterable, Identifiable {
    case movie
    case series

    var id: String { rawValue }
    var title: String { self == .movie ? "Movies" : "Series" }
    var singular: String { self == .movie ? "Movie" : "Series" }
}

/// A title as shown in lists: what a Cinemeta catalogue entry provides.
struct MediaItem: Identifiable, Hashable, Codable {
    let id: String          // IMDb id, e.g. tt0111161
    let kind: MediaKind
    var name: String
    var poster: URL?
    var background: URL?
    var logo: URL?
    var year: String?
    var rating: String?
    var genres: [String] = []
    var overview: String?
}

struct Episode: Identifiable, Hashable, Codable {
    let id: String          // Stremio video id, e.g. tt0903747:1:2
    let season: Int
    let number: Int
    var title: String
    var overview: String?
    var thumbnail: URL?
    var released: Date?

    var code: String { String(format: "S%02dE%02d", season, number) }
    var hasAired: Bool { released.map { $0 <= Date() } ?? true }
}

/// Everything the detail page shows.
struct MediaDetail: Hashable {
    var item: MediaItem
    var runtime: String?
    var released: Date?
    var cast: [String] = []
    var directors: [String] = []
    var episodes: [Episode] = []
    var trailerYouTubeID: String?

    /// Regular seasons first, specials (season 0) last.
    var seasons: [Int] {
        let all = Set(episodes.map(\.season))
        return all.filter { $0 > 0 }.sorted() + (all.contains(0) ? [0] : [])
    }

    func episodes(in season: Int) -> [Episode] {
        episodes.filter { $0.season == season }.sorted { $0.number < $1.number }
    }
}

/// What the player is asked to play: a title, and an episode for series.
struct PlaybackTarget: Hashable, Identifiable, Codable {
    var item: MediaItem
    var episode: Episode?

    /// Stremio video id: the IMDb id for films, `id:season:episode` for episodes.
    var videoID: String { episode?.id ?? item.id }
    var id: String { videoID }
    var displayTitle: String {
        guard let episode else { return item.name }
        return "\(item.name) · \(episode.code)"
    }
}

extension KeyedDecodingContainer {
    func flexString(_ key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return String(value) }
        return nil
    }

    func flexInt(_ key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(String.self, forKey: key) { return Int(value) }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return Int(value) }
        return nil
    }

    func strings(_ key: Key) -> [String] {
        (try? decodeIfPresent([String].self, forKey: key)) ?? []
    }

    func url(_ key: Key) -> URL? {
        guard let text = flexString(key), !text.isEmpty else { return nil }
        return URL(string: text)
    }
}
