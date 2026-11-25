import Foundation

enum DebridService: String, CaseIterable, Identifiable, Codable {
    case none, realdebrid, alldebrid, premiumize, torbox, debridlink, easydebrid, offcloud, putio

    var id: String { rawValue }

    var name: String {
        switch self {
        case .none: return "None"
        case .realdebrid: return "Real-Debrid"
        case .alldebrid: return "AllDebrid"
        case .premiumize: return "Premiumize"
        case .torbox: return "TorBox"
        case .debridlink: return "Debrid-Link"
        case .easydebrid: return "EasyDebrid"
        case .offcloud: return "Offcloud"
        case .putio: return "Put.io"
        }
    }

    /// The account page, to renew a plan.
    var accountPage: URL? {
        switch self {
        case .none: return nil
        case .realdebrid: return URL(string: "https://real-debrid.com/premium")
        case .alldebrid: return URL(string: "https://alldebrid.com/offer/")
        case .premiumize: return URL(string: "https://www.premiumize.me/premium")
        case .torbox: return URL(string: "https://torbox.app/pricing")
        case .debridlink: return URL(string: "https://debrid-link.com/premium")
        default: return keyPage
        }
    }

    /// Where the user finds their API key.
    var keyPage: URL? {
        switch self {
        case .none: return nil
        case .realdebrid: return URL(string: "https://real-debrid.com/apitoken")
        case .alldebrid: return URL(string: "https://alldebrid.com/apikeys")
        case .premiumize: return URL(string: "https://www.premiumize.me/account")
        case .torbox: return URL(string: "https://torbox.app/settings")
        case .debridlink: return URL(string: "https://debrid-link.com/webapp/apikey")
        case .easydebrid: return URL(string: "https://paradise-cloud.com/products/easydebrid")
        case .offcloud: return URL(string: "https://offcloud.com/#/account")
        case .putio: return URL(string: "https://app.put.io/oauth")
        }
    }
}

enum TorrentioSort: String, CaseIterable, Identifiable, Codable {
    case quality, qualitysize, seeders, size
    var id: String { rawValue }
    var title: String {
        switch self {
        case .quality: return "Quality, then seeders"
        case .qualitysize: return "Quality, then size"
        case .seeders: return "Seeders"
        case .size: return "Size"
        }
    }
}

/// The options Torrentio reads from the first path segment of its URLs: `key=value|key=value`.
struct TorrentioConfig: Equatable {
    var service: DebridService = .none
    var key: String = ""
    var providers: [String] = []
    var excludedQualities: [String] = []
    var sort: TorrentioSort = .quality
    var maxSizeGB: Int = 0
    var cachedOnly = true
    /// Torrentio's address; a self-hosted instance can stand in for the public one.
    var server: String = Torrentio.base
    /// Torrentio's `language=` priority, e.g. ["french"]: those releases are listed first.
    var priorityLanguages: [String] = []
    /// Torrentio's `limit=`: results per quality; 0 for all.
    var perQualityLimit: Int = 0
    /// Releases with fewer seeders are hidden (applied here; uncached torrents only).
    var minSeeders: Int = 0

    static let allProviders = [
        "yts", "eztv", "rarbg", "1337x", "thepiratebay", "kickasstorrents", "torrentgalaxy", "magnetdl",
        "horriblesubs", "nyaasi", "tokyotosho", "anidex", "rutor", "rutracker", "comando", "bludv",
        "torrent9", "ilcorsaronero", "mejortorrent", "wolfmax4k", "cinecalidad",
    ]
    /// The language names Torrentio's `language=` option takes.
    static let languageOptions = [
        "english", "japanese", "russian", "italian", "portuguese", "spanish", "latino", "korean", "chinese", "taiwanese",
        "french", "german", "dutch", "hindi", "telugu", "tamil", "polish", "lithuanian", "latvian", "estonian", "czech",
        "slovakian", "slovenian", "hungarian", "romanian", "bulgarian", "serbian", "croatian", "ukrainian", "greek",
        "danish", "finnish", "swedish", "norwegian", "turkish", "arabic", "persian", "hebrew", "vietnamese", "indonesian",
        "malay", "thai",
    ]
    static let qualityOptions = ["4k", "1080p", "720p", "480p", "scr", "cam", "unknown", "dolbyvision", "hdrall", "threed"]

    var hasDebrid: Bool { service != .none && !key.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Identifies the debrid account in memory caches, so links resolved through one account are
    /// never reused after switching to another. Not stable across launches, and never stored.
    var accountFingerprint: String {
        hasDebrid ? "\(service.rawValue):\(key.trimmingCharacters(in: .whitespacesAndNewlines).hashValue)" : "none"
    }

    /// The server address without a trailing slash, or the public instance when it isn't usable.
    var serverBase: String {
        var text = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix("/manifest.json") { text.removeLast("/manifest.json".count) }
        guard let url = URL(string: text), url.scheme?.hasPrefix("http") == true, url.host != nil else { return Torrentio.base }
        return text
    }

    var pathSegment: String {
        var pairs: [String] = []
        if !providers.isEmpty { pairs.append("providers=\(providers.joined(separator: ","))") }
        if sort != .quality { pairs.append("sort=\(sort.rawValue)") }
        if !excludedQualities.isEmpty { pairs.append("qualityfilter=\(excludedQualities.joined(separator: ","))") }
        if maxSizeGB > 0 { pairs.append("sizefilter=\(maxSizeGB)GB") }
        if !priorityLanguages.isEmpty { pairs.append("language=\(priorityLanguages.joined(separator: ","))") }
        if perQualityLimit > 0 { pairs.append("limit=\(perQualityLimit)") }
        if hasDebrid {
            if cachedOnly { pairs.append("debridoptions=nodownloadlinks") }
            let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines).filter { $0 != "|" && $0 != "=" }
            pairs.append("\(service.rawValue)=\(cleanKey)")
        }
        return pairs.joined(separator: "|")
    }
}

enum Torrentio {
    static let base = "https://torrentio.strem.fun"

    static func streams(kind: MediaKind, videoID: String, config: TorrentioConfig) async throws -> [StreamSource] {
        let segment = config.pathSegment
        let configPart = segment.isEmpty ? "" : "/" + (segment.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? segment)
        let id = videoID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/:"))) ?? videoID
        let url = try HTTP.url("\(config.serverBase)\(configPart)/stream/\(kind.rawValue)/\(id).json")
        return try await StremioStreams.fetch(url, addon: "Torrentio")
    }

    /// Torrentio's `/resolve/` links (and the playback links of other addons) make the debrid
    /// service prepare the file, then redirect to it. Follow that one redirect here so the player
    /// gets the final address, and turn Torrentio's "error videos" into readable errors instead of
    /// playing a clip that explains the failure. Only the headers are read: a link that turns out
    /// to be the file itself is cancelled before its body arrives.
    static func resolve(_ source: StreamSource) async throws -> URL {
        guard let url = source.url else { throw ResolveError.notCached }
        guard source.needsResolve else { return url }
        var request = URLRequest(url: url, timeoutInterval: 90)
        request.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await HTTP.session.bytes(for: request, delegate: RedirectStopper.shared)
        bytes.task.cancel()
        guard let http = response as? HTTPURLResponse else { throw ResolveError.unexpected("no response") }
        if let location = http.value(forHTTPHeaderField: "Location"), let target = URL(string: location, relativeTo: url)?.absoluteURL {
            if let failure = ResolveError(errorVideo: target) { throw failure }
            return target
        }
        if (200..<300).contains(http.statusCode) { return url }
        throw ResolveError.unexpected("HTTP \(http.statusCode)")
    }
}

enum ResolveError: LocalizedError, Equatable {
    case accessDenied, downloading, infringement, tooBig, archive, notCached, limit, unexpected(String)

    init?(errorVideo url: URL) {
        // Torrentio's explanatory clips live under /videos/ on its own host (or a self-hosted one).
        guard url.path.contains("/videos/") else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        let known = ["failed_", "downloading"].contains { name.hasPrefix($0) } || name.contains("limit")
        guard url.host?.contains("torrentio") == true || known else { return nil }
        switch true {
        case name.hasPrefix("failed_access"): self = .accessDenied
        case name.hasPrefix("downloading"): self = .downloading
        case name.hasPrefix("failed_infringement"): self = .infringement
        case name.hasPrefix("failed_too_big"): self = .tooBig
        case name.hasPrefix("failed_rar"): self = .archive
        case name.contains("limit"): self = .limit
        default: self = .unexpected(name.replacingOccurrences(of: "_", with: " "))
        }
    }

    var errorDescription: String? {
        switch self {
        case .accessDenied: return "Your debrid service refused the API key. Check it in Settings."
        case .downloading: return "This release isn't cached yet. Your debrid service is downloading it; try another source or come back later."
        case .infringement: return "Your debrid service removed this file. Try another source."
        case .tooBig: return "This file is too big for your debrid service. Try a smaller source."
        case .archive: return "This release is packed in an archive that can't be streamed. Try another source."
        case .notCached: return "This source needs a debrid service. Add one in Settings."
        case .limit: return "Your debrid service's limit was reached. Try again later."
        case let .unexpected(detail): return "Couldn't prepare this source (\(detail))."
        }
    }
}

private final class RedirectStopper: NSObject, URLSessionTaskDelegate {
    static let shared = RedirectStopper()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
