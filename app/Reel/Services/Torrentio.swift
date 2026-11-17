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

    static let allProviders = [
        "yts", "eztv", "rarbg", "1337x", "thepiratebay", "kickasstorrents", "torrentgalaxy", "magnetdl",
        "horriblesubs", "nyaasi", "tokyotosho", "anidex", "rutor", "rutracker", "comando", "bludv",
        "torrent9", "ilcorsaronero", "mejortorrent", "wolfmax4k", "cinecalidad",
    ]
    static let qualityOptions = ["4k", "1080p", "720p", "480p", "scr", "cam", "unknown", "dolbyvision", "hdrall", "threed"]

    var hasDebrid: Bool { service != .none && !key.trimmingCharacters(in: .whitespaces).isEmpty }

    var pathSegment: String {
        var pairs: [String] = []
        if !providers.isEmpty { pairs.append("providers=\(providers.joined(separator: ","))") }
        if sort != .quality { pairs.append("sort=\(sort.rawValue)") }
        if !excludedQualities.isEmpty { pairs.append("qualityfilter=\(excludedQualities.joined(separator: ","))") }
        if maxSizeGB > 0 { pairs.append("sizefilter=\(maxSizeGB)GB") }
        if hasDebrid {
            if cachedOnly { pairs.append("debridoptions=nodownloadlinks") }
            let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines).filter { $0 != "|" && $0 != "=" }
            pairs.append("\(service.rawValue)=\(cleanKey)")
        }
        return pairs.joined(separator: "|")
    }
}

/// One Torrentio result, with the facts its two text fields carry pulled apart.
struct StreamSource: Identifiable, Hashable {
    let id: String
    var quality: String            // "4K", "1080p", …
    var tags: [String]             // "DV", "HDR", "HDR10+", …
    var release: String            // torrent name
    var file: String?              // file inside a pack, when different
    var size: String?
    var sizeBytes: Double
    var seeders: Int?
    var provider: String?
    var languages: String?
    var debridTag: String?         // "RD+", "RD download", …
    var url: URL?                  // debrid resolve link
    var infoHash: String?

    var isCached: Bool { debridTag?.hasSuffix("+") ?? false }
    var isPlayable: Bool { url != nil }

    static let qualityOrder = ["4K", "1080p", "720p", "480p"]
    var qualityRank: Int { Self.qualityOrder.firstIndex(of: quality) ?? Self.qualityOrder.count }
}

enum Torrentio {
    static let base = "https://torrentio.strem.fun"

    static func streams(kind: MediaKind, videoID: String, config: TorrentioConfig) async throws -> [StreamSource] {
        let segment = config.pathSegment
        let configPart = segment.isEmpty ? "" : "/" + (segment.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? segment)
        let id = videoID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/:"))) ?? videoID
        let url = try HTTP.url("\(base)\(configPart)/stream/\(kind.rawValue)/\(id).json")
        let response = try await HTTP.get(url, as: StreamsResponse.self)
        return response.streams.enumerated().map { index, raw in raw.source(index: index) }
    }

    /// Torrentio's `/resolve/` links make the debrid service prepare the file, then redirect to it.
    /// Follow that one redirect here so the player gets the final address, and turn Torrentio's
    /// "error videos" into readable errors instead of playing a clip that explains the failure.
    static func resolve(_ source: StreamSource) async throws -> URL {
        guard let url = source.url else { throw ResolveError.notCached }
        guard url.path.contains("/resolve/") else { return url }
        var request = URLRequest(url: url, timeoutInterval: 90)
        request.setValue("\(AppConfig.name)/1.0", forHTTPHeaderField: "User-Agent")
        let (_, response) = try await HTTP.session.data(for: request, delegate: RedirectStopper.shared)
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
        guard url.host?.contains("torrentio") == true, url.path.contains("/videos/") else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
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

// MARK: - Wire format

private struct StreamsResponse: Decodable {
    let streams: [RawStream]
}

private struct RawStream: Decodable {
    var name: String?
    var title: String?
    var url: String?
    var infoHash: String?
    var behaviorHints: Hints?

    struct Hints: Decodable { var filename: String?; var bingeGroup: String? }

    func source(index: Int) -> StreamSource {
        // name: "[RD+] Torrentio\n4k DV | HDR"   title: "Release\nfile.mkv\n👤 12 💾 4.1 GB ⚙️ YTS\n🇬🇧"
        let nameLines = (name ?? "").components(separatedBy: "\n")
        let head = nameLines.first ?? ""
        let debridTag = head.range(of: #"\[([^\]]+)\]"#, options: .regularExpression).map { String(head[$0].dropFirst().dropLast()) }
        let qualityLine = nameLines.dropFirst().joined(separator: " ")
        let qualityParts = qualityLine.components(separatedBy: CharacterSet(charactersIn: " |")).filter { !$0.isEmpty }
        let rawQuality = qualityParts.first ?? ""
        let quality = rawQuality.lowercased() == "4k" ? "4K" : (rawQuality.isEmpty ? "Other" : rawQuality)
        let tags = Array(qualityParts.dropFirst())

        let lines = (title ?? "").components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let statsIndex = lines.firstIndex { $0.contains("👤") || $0.contains("💾") || $0.contains("⚙️") }
        let textLines = statsIndex.map { Array(lines[..<$0]) } ?? lines
        let stats = statsIndex.map { lines[$0] } ?? ""
        let afterStats = statsIndex.map { Array(lines[($0 + 1)...]) } ?? []

        let seeders = Self.capture(#"👤\s*(\d+)"#, in: stats).flatMap(Int.init)
        let size = Self.capture(#"💾\s*([\d.,]+\s*[KMGT]?B)"#, in: stats)
        let provider = Self.capture(#"⚙️\s*(.+)$"#, in: stats)?.trimmingCharacters(in: .whitespaces)

        return StreamSource(
            id: "\(index)-\(infoHash ?? url ?? name ?? "")",
            quality: quality,
            tags: tags,
            release: textLines.first ?? behaviorHints?.filename ?? "Unknown release",
            file: textLines.count > 1 ? textLines.last : nil,
            size: size,
            sizeBytes: size.map(Self.bytes) ?? 0,
            seeders: seeders,
            provider: provider,
            languages: afterStats.isEmpty ? nil : afterStats.joined(separator: " "),
            debridTag: debridTag,
            url: url.flatMap(URL.init(string:)),
            infoHash: infoHash
        )
    }

    static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    static func bytes(_ size: String) -> Double {
        let parts = size.replacingOccurrences(of: ",", with: ".").split(separator: " ")
        guard let number = parts.first.flatMap({ Double($0) }) else { return 0 }
        let unit = parts.count > 1 ? String(parts[1]) : "B"
        let power = ["B": 0.0, "KB": 1, "MB": 2, "GB": 3, "TB": 4][unit] ?? 0
        return number * pow(1024, power)
    }
}
