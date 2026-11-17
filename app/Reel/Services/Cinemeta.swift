import Foundation

/// Stremio's public metadata catalogue: popular and top-rated lists, search, and title details
/// with episode lists. No key needed. Ids are IMDb ids, which is what Torrentio looks up.
enum Cinemeta {
    enum Catalog: String, CaseIterable, Identifiable {
        case popular = "top"
        case topRated = "imdbRating"

        var id: String { rawValue }
        var title: String { self == .popular ? "Popular" : "Top Rated" }
    }

    static let pageSize = 50
    static let genres = [
        "Action", "Adventure", "Animation", "Comedy", "Crime", "Documentary", "Drama", "Family",
        "Fantasy", "History", "Horror", "Mystery", "Romance", "Sci-Fi", "Thriller", "War", "Western",
    ]

    private static let catalogBase = "https://cinemeta-catalogs.strem.io"
    private static let apiBase = "https://v3-cinemeta.strem.io"

    static func catalog(_ kind: MediaKind, _ catalog: Catalog = .popular, genre: String? = nil, page: Int = 0) async throws -> [MediaItem] {
        var extras: [String] = []
        if let genre, !genre.isEmpty { extras.append("genre=\(HTTP.pathValue(genre))") }
        if page > 0 { extras.append("skip=\(page * pageSize)") }
        let extra = extras.isEmpty ? "" : "/" + extras.joined(separator: "&")
        let url = try HTTP.url("\(catalogBase)/\(catalog.rawValue)/catalog/\(kind.rawValue)/\(catalog.rawValue)\(extra).json")
        let response = try await HTTP.get(url, as: CatalogResponse.self)
        return response.metas.compactMap { $0.item(fallbackKind: kind) }
    }

    static func search(_ query: String, kind: MediaKind) async throws -> [MediaItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let url = try HTTP.url("\(apiBase)/catalog/\(kind.rawValue)/top/search=\(HTTP.pathValue(trimmed)).json")
        let response = try await HTTP.get(url, as: CatalogResponse.self)
        return response.metas.compactMap { $0.item(fallbackKind: kind) }
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

private struct MetaResponse: Decodable {
    let meta: RawMeta?
}

private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
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

    static func parse(_ text: String) -> Date? {
        iso.date(from: text) ?? isoPlain.date(from: text)
    }
}
