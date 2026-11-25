import Foundation

/// Stremio's public metadata catalogue: popular and top-rated lists, search, and title details
/// with episode lists. No key needed. Ids are IMDb ids, which is what Torrentio looks up.
enum Cinemeta {
    enum Catalog: String, CaseIterable, Identifiable {
        case popular = "top"
        case newest = "year"
        case topRated = "imdbRating"

        var id: String { rawValue }
        var title: String {
            switch self {
            case .popular: return "Popular"
            case .newest: return "New"
            case .topRated: return "Top Rated"
            }
        }
        /// The "year" list needs a year where the others take a genre.
        var filtersByYear: Bool { self == .newest }
    }

    /// Years the New list offers, newest first.
    static var recentYears: [String] {
        let year = Calendar.current.component(.year, from: Date())
        return (0..<12).map { String(year - $0) }
    }

    static let pageSize = 50
    static let genres = [
        "Action", "Adventure", "Animation", "Biography", "Comedy", "Crime", "Documentary", "Drama", "Family",
        "Fantasy", "History", "Horror", "Mystery", "Romance", "Sci-Fi", "Sport", "Thriller", "War", "Western",
    ]

    /// The genres Cinemeta lists for films or for series; series add the television ones.
    static func genres(for kind: MediaKind) -> [String] {
        kind == .movie ? genres : (genres + ["Reality-TV", "Talk-Show", "Game-Show"]).sorted()
    }

    private static let catalogBase = "https://cinemeta-catalogs.strem.io"
    private static let apiBase = "https://v3-cinemeta.strem.io"

    static func catalog(_ kind: MediaKind, _ catalog: Catalog = .popular, genre: String? = nil, page: Int = 0) async throws -> [MediaItem] {
        var extras: [String] = []
        var genre = genre
        if catalog.filtersByYear, genre.map({ Int($0) == nil }) ?? true { genre = recentYears.first }
        if let genre, !genre.isEmpty { extras.append("genre=\(HTTP.pathValue(genre))") }
        if page > 0 { extras.append("skip=\(page * pageSize)") }
        let extra = extras.isEmpty ? "" : "/" + extras.joined(separator: "&")
        let url = try HTTP.url("\(catalogBase)/\(catalog.rawValue)/catalog/\(kind.rawValue)/\(catalog.rawValue)\(extra).json")
        let response = try await HTTP.get(url, as: CatalogResponse.self)
        let items = response.metas.compactMap { $0.item(fallbackKind: kind) }
        // Early in January this year's list is nearly empty: follow it with last year's.
        if catalog == .newest, page == 0, items.count < 20, let year = genre.flatMap(Int.init),
           year == Calendar.current.component(.year, from: Date()),
           let previous = try? await self.catalog(kind, .newest, genre: String(year - 1)) {
            let known = Set(items.map(\.id))
            return items + previous.filter { !known.contains($0.id) }
        }
        return items
    }

    static func search(_ query: String, kind: MediaKind) async throws -> [MediaItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let url = try HTTP.url("\(apiBase)/catalog/\(kind.rawValue)/top/search=\(HTTP.pathValue(trimmed)).json")
        let response = try await HTTP.get(url, as: CatalogResponse.self)
        return response.metas.compactMap { $0.item(fallbackKind: kind) }
    }

    /// Titles a person is in or directed. Cinemeta's search matches cast and directors as well as
    /// names; results that don't credit the person (a title merely named like them) are dropped
    /// unless nothing else is left.
    static func person(_ name: String) async throws -> (movies: [MediaItem], series: [MediaItem], directed: Set<String>) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ([], [], []) }
        func credits(_ kind: MediaKind) async throws -> ([MediaItem], Set<String>) {
            let url = try HTTP.url("\(apiBase)/catalog/\(kind.rawValue)/top/search=\(HTTP.pathValue(trimmed)).json")
            let metas = try await HTTP.get(url, as: CatalogResponse.self).metas
            let key = trimmed.lowercased()
            let credited = metas.filter { meta in
                (meta.cast + meta.director).contains { $0.lowercased() == key }
            }
            let chosen = credited.isEmpty ? metas : credited
            let directed = Set(chosen.filter { $0.director.contains { $0.lowercased() == key } }.compactMap { $0.item(fallbackKind: kind)?.id })
            return (chosen.compactMap { $0.item(fallbackKind: kind) }, directed)
        }
        async let movies = credits(.movie)
        async let series = credits(.series)
        let (m, s) = try await (movies, series)
        return (m.0, s.0, m.1.union(s.1))
    }

    /// The latest and next episodes of many series in one request, the way Stremio's calendar
    /// gets them: each series comes back with about ten episodes around today.
    static func calendar(seriesIDs: [String]) async throws -> [MediaDetail] {
        var seen = Set<String>()
        let ids = seriesIDs.filter { $0.hasPrefix("tt") && seen.insert($0).inserted }
        guard !ids.isEmpty else { return [] }
        let chunks = stride(from: 0, to: ids.count, by: 40).map { Array(ids[$0..<min($0 + 40, ids.count)]) }
        var details: [MediaDetail] = []
        var firstError: Error?
        // Three requests at a time: quicker for a long list, still gentle on Cinemeta.
        for batch in stride(from: 0, to: chunks.count, by: 3).map({ Array(chunks[$0..<min($0 + 3, chunks.count)]) }) {
            let results = await withTaskGroup(of: Result<[MediaDetail], Error>.self) { group in
                for chunk in batch {
                    group.addTask {
                        await asyncResult {
                            let joined = chunk.joined(separator: ",")
                            let url = try HTTP.url("\(apiBase)/catalog/series/calendar-videos/calendarVideosIds=\(joined).json")
                            let response = try await HTTP.get(url, as: DetailedResponse.self)
                            return response.metasDetailed.compactMap { $0.detail(fallbackKind: .series) }
                        }
                    }
                }
                var collected: [Result<[MediaDetail], Error>] = []
                for await result in group { collected.append(result) }
                return collected
            }
            for result in results {
                switch result {
                case let .success(found): details += found
                case let .failure(error): firstError = firstError ?? error
                }
            }
        }
        if details.isEmpty, let firstError { throw firstError }
        return details
    }

    static func detail(_ kind: MediaKind, id: String) async throws -> MediaDetail {
        let url = try HTTP.url("\(apiBase)/meta/\(kind.rawValue)/\(HTTP.pathValue(id)).json")
        let response = try await HTTP.get(url, as: MetaResponse.self)
        guard let detail = response.meta?.detail(fallbackKind: kind) else {
            throw HTTPError.status(404, url)
        }
        return detail
    }
}

// MARK: - Wire format

private struct CatalogResponse: Decodable {
    let metas: [RawMeta]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // One malformed entry must not empty the whole row.
        metas = (try? container.decode([Lossy<RawMeta>].self, forKey: .metas))?.compactMap(\.value) ?? []
    }

    enum CodingKeys: String, CodingKey { case metas }
}

private struct DetailedResponse: Decodable {
    let metasDetailed: [RawMeta]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metasDetailed = (try? container.decode([Lossy<RawMeta>].self, forKey: .metasDetailed))?.compactMap(\.value) ?? []
    }

    enum CodingKeys: String, CodingKey { case metasDetailed }
}

private struct MetaResponse: Decodable {
    let meta: RawMeta?
}


private struct RawMeta: Decodable {
    var id: String?
    var imdbID: String?
    var type: String?
    var name: String?
    var poster: URL?
    var background: URL?
    var logo: URL?
    var description: String?
    var releaseInfo: String?
    var year: String?
    var released: String?
    var imdbRating: String?
    var genres: [String] = []
    var cast: [String] = []
    var director: [String] = []
    var runtime: String?
    var trailers: [String] = []
    var videos: [RawVideo] = []

    enum CodingKeys: String, CodingKey {
        case id, imdb_id, type, name, poster, background, logo, description, releaseInfo, year
        case released, imdbRating, genres, genre, cast, director, runtime, trailers, videos
    }

    private struct Trailer: Decodable { let source: String?; let type: String? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexString(.id)
        imdbID = c.flexString(.imdb_id)
        type = c.flexString(.type)
        name = c.flexString(.name)
        poster = c.url(.poster)
        background = c.url(.background)
        logo = c.url(.logo)
        description = c.flexString(.description)
        releaseInfo = c.flexString(.releaseInfo)
        year = c.flexString(.year)
        released = c.flexString(.released)
        imdbRating = c.flexString(.imdbRating)
        genres = c.strings(.genres)
        if genres.isEmpty { genres = c.strings(.genre) }
        cast = c.strings(.cast)
        director = c.strings(.director)
        runtime = c.flexString(.runtime)
        let trailerList = (try? c.decodeIfPresent([Lossy<Trailer>].self, forKey: .trailers)) ?? nil
        trailers = (trailerList ?? []).compactMap { $0.value }.filter { ($0.type ?? "Trailer") == "Trailer" }.compactMap(\.source)
        videos = ((try? c.decodeIfPresent([Lossy<RawVideo>].self, forKey: .videos)) ?? nil)?.compactMap(\.value) ?? []
    }

    func item(fallbackKind: MediaKind) -> MediaItem? {
        guard let imdb = [imdbID, id].compactMap({ $0 }).first(where: { $0.hasPrefix("tt") }),
              let name, !name.isEmpty else { return nil }
        let kind = type.flatMap(MediaKind.init(rawValue:)) ?? fallbackKind
        let rating = imdbRating.flatMap { Double($0) }.map { String(format: "%.1f", $0) }
        return MediaItem(
            id: imdb,
            kind: kind,
            name: name,
            poster: Self.metahub(poster, size: "medium"),
            background: Self.metahub(background, size: "large"),
            logo: Self.metahub(logo, size: "medium"),
            year: releaseInfo ?? year,
            rating: rating,
            genres: genres,
            overview: description
        )
    }

    func detail(fallbackKind: MediaKind) -> MediaDetail? {
        guard let item = item(fallbackKind: fallbackKind) else { return nil }
        let episodes = videos.compactMap { $0.episode(seriesID: item.id) }
        return MediaDetail(
            item: item,
            runtime: runtime,
            released: released.flatMap(DateParsing.parse),
            cast: Array(cast.prefix(12)),
            directors: director,
            episodes: episodes,
            trailerYouTubeID: trailers.first
        )
    }

    /// Metahub serves several sizes behind the same path; pick a sharper one than the catalogue's.
    static func metahub(_ url: URL?, size: String) -> URL? {
        guard let url else { return nil }
        let text = url.absoluteString.replacingOccurrences(
            of: #"/(poster|background|logo)/(small|medium|large)/"#,
            with: "/$1/\(size)/",
            options: .regularExpression
        )
        return URL(string: text) ?? url
    }
}

private struct RawVideo: Decodable {
    var id: String?
    var season: Int?
    var episode: Int?
    var title: String?
    var overview: String?
    var thumbnail: URL?
    var released: String?

    enum CodingKeys: String, CodingKey { case id, season, episode, number, name, title, overview, description, thumbnail, released, firstAired }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexString(.id)
        season = c.flexInt(.season)
        episode = c.flexInt(.episode) ?? c.flexInt(.number)
        title = c.flexString(.name) ?? c.flexString(.title)
        overview = c.flexString(.overview) ?? c.flexString(.description)
        thumbnail = c.url(.thumbnail)
        released = c.flexString(.released) ?? c.flexString(.firstAired)
    }

    func episode(seriesID: String) -> Episode? {
        guard let season, let episode, season >= 0, episode > 0 else { return nil }
        return Episode(
            id: id ?? "\(seriesID):\(season):\(episode)",
            season: season,
            number: episode,
            title: (title?.isEmpty == false ? title : nil) ?? "Episode \(episode)",
            overview: overview,
            thumbnail: thumbnail,
            released: released.flatMap(DateParsing.parse)
        )
    }
}

enum DateParsing {
    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let isoPlain = ISO8601DateFormatter()

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func parse(_ text: String) -> Date? {
        iso.date(from: text) ?? isoPlain.date(from: text)
    }

    /// A bare date, "2026-11-25".
    static func parseDay(_ text: String) -> Date? {
        day.date(from: String(text.prefix(10)))
    }
}
