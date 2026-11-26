import Foundation

/// The parts of the Trakt API the app uses: device sign-in, scrobbling, the watchlist, playback
/// progress and watched history. https://trakt.docs.apiary.io
enum Trakt {
    static let base = "https://api.trakt.tv"
    static let redirect = "urn:ietf:wg:oauth:2.0:oob"

    struct Credentials: Codable, Equatable {
        var clientID: String
        var clientSecret: String
    }

    struct Token: Codable, Equatable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date

        var isExpiring: Bool { expiresAt.timeIntervalSinceNow < 24 * 3600 }
    }

    struct DeviceCode: Decodable {
        let deviceCode: String
        let userCode: String
        let verificationURL: String
        let expiresIn: Int
        let interval: Int

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code", userCode = "user_code", verificationURL = "verification_url"
            case expiresIn = "expires_in", interval
        }
    }

    enum PollResult {
        case pending, slowDown, token(Token), failed(String)
    }

    enum TraktError: LocalizedError {
        case status(Int)
        var errorDescription: String? {
            switch self {
            case .status(401): return "Trakt signed this app out. Connect again in Settings."
            case let .status(code): return "Trakt answered \(code)."
            }
        }
    }

    // MARK: Sign-in

    static func deviceCode(_ credentials: Credentials) async throws -> DeviceCode {
        let data = try await post("/oauth/device/code", body: ["client_id": credentials.clientID], credentials: credentials, token: nil)
        return try JSONDecoder().decode(DeviceCode.self, from: data)
    }

    static func poll(_ code: DeviceCode, credentials: Credentials) async -> PollResult {
        do {
            let body = ["code": code.deviceCode, "client_id": credentials.clientID, "client_secret": credentials.clientSecret]
            let data = try await post("/oauth/device/token", body: body, credentials: credentials, token: nil)
            return .token(try decodeToken(data))
        } catch TraktError.status(400) {
            return .pending
        } catch TraktError.status(429) {
            return .slowDown
        } catch TraktError.status(let code) {
            switch code {
            case 404: return .failed("Trakt didn't recognise the code. Start again.")
            case 409: return .failed("That code was already used. Start again.")
            case 410: return .failed("The code expired. Start again.")
            case 418: return .failed("The connection was declined on Trakt.")
            default: return .failed("Trakt answered \(code).")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func refresh(_ token: Token, credentials: Credentials) async throws -> Token {
        let body = [
            "refresh_token": token.refreshToken, "client_id": credentials.clientID,
            "client_secret": credentials.clientSecret, "redirect_uri": redirect, "grant_type": "refresh_token",
        ]
        let data = try await post("/oauth/token", body: body, credentials: credentials, token: nil)
        return try decodeToken(data)
    }

    private static func decodeToken(_ data: Data) throws -> Token {
        struct Raw: Decodable {
            let access_token: String
            let refresh_token: String
            let expires_in: Double
            let created_at: Double
        }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        return Token(accessToken: raw.access_token, refreshToken: raw.refresh_token,
                     expiresAt: Date(timeIntervalSince1970: raw.created_at + raw.expires_in))
    }

    // MARK: Scrobbling

    enum ScrobbleAction: String { case start, pause, stop }

    static func scrobble(_ action: ScrobbleAction, target: PlaybackTarget, progress: Double,
                         credentials: Credentials, token: Token) async throws {
        var body = identity(target)
        body["progress"] = max(0, min(100, progress))
        _ = try await post("/scrobble/\(action.rawValue)", body: body, credentials: credentials, token: token)
    }

    private static func identity(_ target: PlaybackTarget) -> [String: Any] {
        if let episode = target.episode {
            return ["show": ["ids": ["imdb": target.item.id]], "episode": ["season": episode.season, "number": episode.number]]
        }
        return ["movie": ["ids": ["imdb": target.item.id]]]
    }

    // MARK: Watchlist

    static func watchlist(credentials: Credentials, token: Token) async throws -> [MediaItem] {
        async let movies: [ListEntry] = get("/sync/watchlist/movies", credentials: credentials, token: token)
        async let shows: [ListEntry] = get("/sync/watchlist/shows", credentials: credentials, token: token)
        let all = try await movies + shows
        return all.compactMap(\.mediaItem)
    }

    static func setWatchlist(_ item: MediaItem, included: Bool, credentials: Credentials, token: Token) async throws {
        let key = item.kind == .movie ? "movies" : "shows"
        let body: [String: Any] = [key: [["ids": ["imdb": item.id]]]]
        _ = try await post(included ? "/sync/watchlist" : "/sync/watchlist/remove", body: body, credentials: credentials, token: token)
    }

    // MARK: Progress and history

    struct Resume {
        let target: PlaybackTarget
        let fraction: Double
        let runtimeSeconds: Double
        let pausedAt: Date
    }

    static func playback(credentials: Credentials, token: Token) async throws -> [Resume] {
        let entries: [PlaybackEntry] = try await get("/sync/playback?extended=full", credentials: credentials, token: token)
        return entries.compactMap(\.resume)
    }

    /// Watched films by IMDb id, and watched episodes as Stremio video ids ("tt…:1:2").
    static func watched(credentials: Credentials, token: Token) async throws -> (movies: Set<String>, episodes: Set<String>) {
        async let movies: [WatchedMovie] = get("/sync/watched/movies", credentials: credentials, token: token)
        async let shows: [WatchedShow] = get("/sync/watched/shows", credentials: credentials, token: token)
        let movieIDs = Set(try await movies.compactMap { $0.movie.ids.imdb })
        let fullShows = try await shows
        var episodeIDs = Set<String>()
        for show in fullShows {
            guard let imdb = show.show.ids.imdb else { continue }
            for season in show.seasons ?? [] {
                for episode in season.episodes { episodeIDs.insert("\(imdb):\(season.number):\(episode.number)") }
            }
        }
        return (movieIDs, episodeIDs)
    }

    // MARK: History and ratings

    /// Adds (with `watchedAt`) or removes films and episodes from Trakt's watched history.
    static func history(_ targets: [PlaybackTarget], watched: Bool, at date: Date,
                        credentials: Credentials, token: Token) async throws {
        let stamp = ISO8601DateFormatter.trakt.string(from: date)
        var movies: [[String: Any]] = []
        var shows: [String: [Int: [[String: Any]]]] = [:]
        for target in targets {
            if let episode = target.episode {
                var entry: [String: Any] = ["number": episode.number]
                if watched { entry["watched_at"] = stamp }
                shows[target.item.id, default: [:]][episode.season, default: []].append(entry)
            } else {
                var entry: [String: Any] = ["ids": ["imdb": target.item.id]]
                if watched { entry["watched_at"] = stamp }
                movies.append(entry)
            }
        }
        let showBodies: [[String: Any]] = shows.map { imdb, seasons in
            ["ids": ["imdb": imdb], "seasons": seasons.map { ["number": $0.key, "episodes": $0.value] }]
        }
        var body: [String: Any] = [:]
        if !movies.isEmpty { body["movies"] = movies }
        if !showBodies.isEmpty { body["shows"] = showBodies }
        guard !body.isEmpty else { return }
        _ = try await post(watched ? "/sync/history" : "/sync/history/remove", body: body, credentials: credentials, token: token)
    }

    /// Rates a film or series from 1 to 10; 0 removes the rating.
    static func rate(_ item: MediaItem, rating: Int, credentials: Credentials, token: Token) async throws {
        let key = item.kind == .movie ? "movies" : "shows"
        var entry: [String: Any] = ["ids": ["imdb": item.id]]
        if rating > 0 { entry["rating"] = rating }
        _ = try await post(rating > 0 ? "/sync/ratings" : "/sync/ratings/remove", body: [key: [entry]], credentials: credentials, token: token)
    }

    /// When each part of the account last changed, so a sync can skip what hasn't.
    static func lastActivities(credentials: Credentials, token: Token) async throws -> [String: String] {
        let request = try request("/sync/last_activities", method: "GET", credentials: credentials, token: token)
        let (data, response) = try await HTTP.session.data(for: request)
        try check(response)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        func stamp(_ group: String, _ field: String) -> String { ((json[group] as? [String: Any])?[field] as? String) ?? "" }
        return [
            "watched": stamp("movies", "watched_at") + stamp("episodes", "watched_at"),
            "watchlist": stamp("movies", "watchlisted_at") + stamp("shows", "watchlisted_at"),
            "playback": stamp("movies", "paused_at") + stamp("episodes", "paused_at"),
        ]
    }

    // MARK: Discovery

    enum Discovery: String, CaseIterable {
        case trending, popular, anticipated, recommended

        var title: String {
            switch self {
            case .trending: return "Trending"
            case .popular: return "Popular on Trakt"
            case .anticipated: return "Most Anticipated"
            case .recommended: return "Recommended for You"
            }
        }

        var needsSignIn: Bool { self == .recommended }
    }

    /// A Trakt list of films or shows. Trending and anticipated wrap each title in an object;
    /// popular and recommended list them bare. Both are read.
    static func discover(_ list: Discovery, kind: MediaKind, credentials: Credentials, token: Token?) async throws -> [MediaItem] {
        let type = kind == .movie ? "movies" : "shows"
        let path = list == .recommended ? "/recommendations/\(type)?limit=30&ignore_collected=true" : "/\(type)/\(list.rawValue)?limit=30"
        let request = try request(path, method: "GET", credentials: credentials, token: list.needsSignIn ? token : nil)
        let (data, response) = try await HTTP.session.data(for: request)
        try check(response)
        let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        let key = kind == .movie ? "movie" : "show"
        return entries.compactMap { entry -> MediaItem? in
            let work = (entry[key] as? [String: Any]) ?? entry
            guard let ids = work["ids"] as? [String: Any], let imdb = ids["imdb"] as? String, imdb.hasPrefix("tt") else { return nil }
            let decoded = Work(title: work["title"] as? String, year: work["year"] as? Int, ids: IDs(imdb: imdb), runtime: nil)
            return item(id: imdb, kind: kind, work: decoded)
        }
    }

    // MARK: Related and lists

    /// Titles Trakt's users watch alongside this one.
    static func related(_ item: MediaItem, credentials: Credentials) async throws -> [MediaItem] {
        let type = item.kind == .movie ? "movies" : "shows"
        let request = try request("/\(type)/\(item.id)/related?limit=20", method: "GET", credentials: credentials, token: nil)
        let (data, response) = try await HTTP.session.data(for: request)
        try check(response)
        return parseWorks(data, kind: item.kind)
    }

    struct List: Identifiable, Hashable, Sendable {
        let id: Int
        let name: String
        let itemCount: Int
        let description: String?
    }

    /// The signed-in user's own lists.
    static func lists(credentials: Credentials, token: Token) async throws -> [List] {
        let request = try request("/users/me/lists", method: "GET", credentials: credentials, token: token)
        let (data, response) = try await HTTP.session.data(for: request)
        try check(response)
        let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        return entries.compactMap { entry in
            guard let ids = entry["ids"] as? [String: Any], let id = ids["trakt"] as? Int else { return nil }
            return List(id: id, name: entry["name"] as? String ?? "List", itemCount: entry["item_count"] as? Int ?? 0,
                        description: (entry["description"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    /// The films and series on one of the user's lists, in its order.
    static func listItems(_ list: List, credentials: Credentials, token: Token) async throws -> [MediaItem] {
        let request = try request("/users/me/lists/\(list.id)/items/movie,show", method: "GET", credentials: credentials, token: token)
        let (data, response) = try await HTTP.session.data(for: request)
        try check(response)
        let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        return entries.compactMap { entry in
            for (key, kind) in [("movie", MediaKind.movie), ("show", .series)] {
                if let work = entry[key] as? [String: Any], let item = workItem(work, kind: kind) { return item }
            }
            return nil
        }
    }

    private static func parseWorks(_ data: Data, kind: MediaKind) -> [MediaItem] {
        let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        let key = kind == .movie ? "movie" : "show"
        return entries.compactMap { workItem((($0[key] as? [String: Any]) ?? $0), kind: kind) }
    }

    private static func workItem(_ work: [String: Any], kind: MediaKind) -> MediaItem? {
        guard let ids = work["ids"] as? [String: Any], let imdb = ids["imdb"] as? String, imdb.hasPrefix("tt") else { return nil }
        let decoded = Work(title: work["title"] as? String, year: work["year"] as? Int, ids: IDs(imdb: imdb), runtime: nil)
        return item(id: imdb, kind: kind, work: decoded)
    }

    // MARK: Wire format

    struct IDs: Decodable { let imdb: String? }
    struct Work: Decodable {
        let title: String?
        let year: Int?
        let ids: IDs
        let runtime: Int?
    }
    struct EpisodeRef: Decodable {
        let season: Int
        let number: Int
        let title: String?
        let runtime: Int?
    }

    private struct ListEntry: Decodable {
        let movie: Work?
        let show: Work?

        var mediaItem: MediaItem? {
            if let movie, let id = movie.ids.imdb { return Trakt.item(id: id, kind: .movie, work: movie) }
            if let show, let id = show.ids.imdb { return Trakt.item(id: id, kind: .series, work: show) }
            return nil
        }
    }

    private struct PlaybackEntry: Decodable {
        let progress: Double
        let paused_at: String?
        let type: String
        let movie: Work?
        let show: Work?
        let episode: EpisodeRef?

        var resume: Resume? {
            let pausedAt = paused_at.flatMap { ISO8601DateFormatter.trakt.date(from: $0) } ?? Date()
            if type == "movie", let movie, let id = movie.ids.imdb {
                return Resume(target: PlaybackTarget(item: Trakt.item(id: id, kind: .movie, work: movie)),
                              fraction: progress / 100, runtimeSeconds: Double(movie.runtime ?? 110) * 60, pausedAt: pausedAt)
            }
            if type == "episode", let show, let id = show.ids.imdb, let episode {
                let ep = Episode(id: "\(id):\(episode.season):\(episode.number)", season: episode.season, number: episode.number,
                                 title: episode.title ?? "Episode \(episode.number)")
                return Resume(target: PlaybackTarget(item: Trakt.item(id: id, kind: .series, work: show), episode: ep),
                              fraction: progress / 100, runtimeSeconds: Double(episode.runtime ?? show.runtime ?? 45) * 60, pausedAt: pausedAt)
            }
            return nil
        }
    }

    private struct WatchedMovie: Decodable { let movie: Work }
    private struct WatchedShow: Decodable {
        let show: Work
        let seasons: [Season]?
        struct Season: Decodable {
            let number: Int
            let episodes: [Number]
        }
        struct Number: Decodable { let number: Int }
    }

    /// A list entry from Trakt with Cinemeta's artwork addresses, which are keyed by IMDb id.
    static func item(id: String, kind: MediaKind, work: Work) -> MediaItem {
        MediaItem(
            id: id, kind: kind, name: work.title ?? id,
            poster: URL(string: "https://images.metahub.space/poster/medium/\(id)/img"),
            background: URL(string: "https://images.metahub.space/background/medium/\(id)/img"),
            logo: URL(string: "https://images.metahub.space/logo/medium/\(id)/img"),
            year: work.year.map(String.init)
        )
    }

    // MARK: Requests

    static func request(_ path: String, method: String, credentials: Credentials, token: Token?) throws -> URLRequest {
        var request = URLRequest(url: try HTTP.url(base + path), timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(credentials.clientID, forHTTPHeaderField: "trakt-api-key")
        if let token { request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private static func get<T: Decodable>(_ path: String, credentials: Credentials, token: Token) async throws -> T {
        let request = try request(path, method: "GET", credentials: credentials, token: token)
        let (data, response) = try await HTTP.session.data(for: request)
        try check(response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    @discardableResult
    private static func post(_ path: String, body: [String: Any], credentials: Credentials, token: Token?) async throws -> Data {
        var request = try request(path, method: "POST", credentials: credentials, token: token)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await HTTP.session.data(for: request)
        try check(response)
        return data
    }

    static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else { throw TraktError.status(http.statusCode) }
    }
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let trakt: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
