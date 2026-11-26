import Foundation

/// One playable release from Torrentio or another Stremio addon, with the facts its free-text
/// fields carry pulled apart.
struct StreamSource: Identifiable, Hashable, Codable {
    let id: String
    var addon: String              // "Torrentio", "Comet", …
    var addonHost: String?         // the addon's own host: links on it redirect to the file
    var quality: String            // "4K", "1080p", …
    var tags: [String]             // "DV", "HDR", "HDR10+", "Atmos", …
    var release: String            // torrent name
    var file: String?              // file inside a pack, when different
    var size: String?
    var sizeBytes: Double
    var seeders: Int?
    var provider: String?
    var languages: String?
    var debridTag: String?         // "RD+", "RD⚡", "RD download", …
    var cached: Bool
    var url: URL?                  // debrid resolve link or direct file
    var infoHash: String?
    var fileIndex: Int?
    var bingeGroup: String?

    var isCached: Bool { cached }
    var isPlayable: Bool { url != nil }

    static let qualityOrder = ["4K", "1080p", "720p", "480p"]
    var qualityRank: Int { Self.qualityOrder.firstIndex(of: quality) ?? Self.qualityOrder.count }

    /// Identifies the same file across addons and sessions: the torrent and the file in it.
    var fileKey: String {
        if let infoHash { return "\(infoHash.lowercased()):\(fileIndex.map(String.init) ?? file ?? "")" }
        return url?.absoluteString ?? id
    }

    /// The scene group that made the release ("FLUX" in "Movie.2024.2160p.WEB-DL.DV-FLUX.mkv").
    var releaseGroup: String? {
        let name = Pattern.videoExtensionAtEnd.replacing(in: file ?? release, with: "")
        guard let group = Pattern.releaseGroup.firstGroup(in: name), !group.isEmpty else { return nil }
        return group.uppercased()
    }

    var hasDolbyVision: Bool { tags.contains("DV") }
    var hasHDR: Bool { tags.contains { ["HDR", "HDR10", "HDR10+", "DV", "HLG"].contains($0) } }

    /// A link on the addon's own host (or a Torrentio /resolve/ link) answers with a redirect to
    /// the real file; anything else already is the file.
    var needsResolve: Bool {
        guard let url else { return false }
        if url.path.contains("/resolve/") { return true }
        if let addonHost, url.host == addonHost { return true }
        return false
    }
}

/// Reads a Stremio `/stream/` response. Torrentio, Comet, MediaFusion and most other addons share
/// the wire format but each writes its own `name`/`title` text, so the parsing is heuristic and
/// only ever adds facts: a field it cannot read stays empty.
enum StremioStreams {
    static func fetch(_ url: URL, addon: String) async throws -> [StreamSource] {
        let response = try await HTTP.get(url, as: Response.self)
        return response.streams.enumerated().compactMap { index, raw in
            raw.source(index: index, addon: addon, addonHost: url.host)
        }
    }

    struct Response: Decodable {
        let streams: [RawStream]
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            streams = (try? container.decode([RawStream].self, forKey: .streams)) ?? []
        }
        enum CodingKeys: String, CodingKey { case streams }
    }

    struct RawStream: Decodable {
        var name: String?
        var title: String?
        var description: String?
        var url: String?
        var infoHash: String?
        var fileIdx: Int?
        var behaviorHints: Hints?

        struct Hints: Decodable {
            var filename: String?
            var bingeGroup: String?
            var videoSize: Double?
        }

        func source(index: Int, addon: String, addonHost: String?) -> StreamSource? {
            // Torrentio: name "[RD+] Torrentio\n4k DV | HDR", title "Release\nfile.mkv\n👤 12 💾 4.1 GB ⚙️ YTS\n🇬🇧"
            // Comet:     name "[RD⚡] Comet 2160p", description "Release\n💾 15.3 GB 🔎 Provider"
            let name = self.name ?? ""
            let text = title ?? description ?? ""
            let nameLines = name.components(separatedBy: "\n")
            let head = nameLines.first ?? ""
            let debridTag = head.range(of: #"\[([^\]]+)\]"#, options: .regularExpression).map { String(head[$0].dropFirst().dropLast()) }
            let cached = (debridTag?.hasSuffix("+") ?? false) || name.contains("⚡") || name.localizedCaseInsensitiveContains("cached")

            let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let statsIndex = lines.firstIndex { $0.contains("👤") || $0.contains("💾") || $0.contains("⚙️") || $0.contains("🔎") }
            let textLines = (statsIndex.map { Array(lines[..<$0]) } ?? lines).filter { !Self.isDecoration($0) }
            // The stats run over the lines that carry their markers; what follows (Torrentio's
            // language flags) is separate, or the provider would read "YTS 🇬🇧 / 🇫🇷".
            let statsLines = statsIndex.map { start in Array(lines[start...].prefix { Self.isStats($0) }) } ?? []
            let stats = statsLines.joined(separator: " ")
            let afterStats = statsIndex.map { Array(lines[($0 + statsLines.count)...]) } ?? []

            let release = textLines.first ?? behaviorHints?.filename ?? "Unknown release"
            let file = textLines.count > 1 ? textLines.last : behaviorHints?.filename.flatMap { $0 == release ? nil : $0 }
            let haystack = [name, release, file ?? "", behaviorHints?.filename ?? ""].joined(separator: " ")

            let size = Pattern.size.firstGroup(in: stats)
            let sizeBytes = size.map(Self.bytes) ?? behaviorHints?.videoSize ?? 0
            let shownSize = size ?? (sizeBytes > 0 ? ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file) : nil)

            return StreamSource(
                id: "\(addon)-\(index)-\(infoHash ?? url ?? name)",
                addon: addon,
                addonHost: addonHost,
                quality: Self.quality(nameLines: nameLines, haystack: haystack),
                tags: Self.tags(nameLines: nameLines, haystack: haystack),
                release: release,
                file: file,
                size: shownSize,
                sizeBytes: sizeBytes,
                seeders: Pattern.seeders.firstGroup(in: stats).flatMap(Int.init),
                provider: (Pattern.providerGear.firstGroup(in: stats) ?? Pattern.providerSearch.firstGroup(in: stats))?.trimmingCharacters(in: .whitespaces),
                languages: afterStats.isEmpty ? nil : afterStats.joined(separator: " "),
                debridTag: debridTag,
                cached: cached,
                url: url.flatMap(URL.init(string:)),
                infoHash: infoHash?.lowercased(),
                fileIndex: fileIdx,
                bingeGroup: behaviorHints?.bingeGroup
            )
        }

        private static func isStats(_ line: String) -> Bool {
            line.contains("👤") || line.contains("💾") || line.contains("⚙️") || line.contains("🔎")
        }

        private static func isDecoration(_ line: String) -> Bool {
            line.hasPrefix("🇬") || line.hasPrefix("🌐") || line.allSatisfy { !$0.isLetter && !$0.isNumber }
        }

        static func quality(nameLines: [String], haystack: String) -> String {
            // Torrentio puts the resolution first on the name's second line.
            if nameLines.count > 1, let first = nameLines[1].split(whereSeparator: { $0 == " " || $0 == "|" }).first {
                let token = first.lowercased()
                if token == "4k" { return "4K" }
                if ["1080p", "720p", "480p"].contains(token) { return token }
            }
            // A ".ts" extension is a container, not a telesync.
            let lower = Pattern.videoExtension.replacing(in: haystack.lowercased(), with: " ")
            if Pattern.uhd.matches(lower) { return "4K" }
            for value in ["1080p", "720p", "480p"] where lower.contains(value) { return value }
            if Pattern.cam.matches(lower) { return "CAM" }
            return "Other"
        }

        static func tags(nameLines: [String], haystack: String) -> [String] {
            var tags: [String] = []
            func add(_ tag: String) { if !tags.contains(tag) { tags.append(tag) } }
            let lower = haystack.lowercased()
            if Pattern.dolbyVision.matches(lower) { add("DV") }
            if Pattern.hdr10Plus.matches(lower) { add("HDR10+") }
            else if Pattern.hdr.matches(lower) { add("HDR") }
            if Pattern.hlg.matches(lower) { add("HLG") }
            if lower.contains("atmos") { add("Atmos") }
            if Pattern.remux.matches(lower) { add("Remux") }
            if Pattern.hevc.matches(lower) { add("HEVC") }
            else if Pattern.av1.matches(lower) { add("AV1") }
            if Pattern.threeD.matches(lower) { add("3D") }
            return tags
        }

        static func bytes(_ size: String) -> Double {
            let parts = size.replacingOccurrences(of: ",", with: ".").split(separator: " ")
            let number: Double
            var unit = "B"
            if parts.count > 1 {
                number = Double(parts[0]) ?? 0
                unit = String(parts[1])
            } else {
                let text = String(parts.first ?? "")
                let digits = text.prefix { $0.isNumber || $0 == "." }
                number = Double(digits) ?? 0
                unit = String(text.dropFirst(digits.count))
            }
            let powers: [String: Double] = ["B": 0, "KB": 1, "MB": 2, "GB": 3, "TB": 4]
            return number * pow(1024, powers[unit.uppercased()] ?? 0)
        }
    }
}

// MARK: - Addons

/// One list an addon offers to browse ("Trending anime", "Netflix new releases").
struct AddonCatalog: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var type: String
    var name: String

    var kind: MediaKind? { MediaKind(rawValue: type) }
}

/// A Stremio addon the user added by its manifest address: its streams join Torrentio's, and its
/// catalogues appear in Explore.
struct StreamAddon: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var base: String           // manifest address without "/manifest.json"
    var types: [String]
    var enabled = true
    /// nil for addons saved before catalogues were read: those were stream addons.
    var providesStreams: Bool?
    var catalogs: [AddonCatalog]?

    var hasStreams: Bool { providesStreams ?? true }

    func supports(_ kind: MediaKind) -> Bool { types.isEmpty || types.contains(kind.rawValue) }

    init(id: String, name: String, base: String, types: [String], enabled: Bool = true,
         providesStreams: Bool? = nil, catalogs: [AddonCatalog]? = nil) {
        self.id = id
        self.name = name
        self.base = base
        self.types = types
        self.enabled = enabled
        self.providesStreams = providesStreams
        self.catalogs = catalogs
    }

    private enum CodingKeys: String, CodingKey { case id, name, base, types, enabled, providesStreams, catalogs }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? id
        base = try c.decode(String.self, forKey: .base)
        types = (try? c.decode([String].self, forKey: .types)) ?? []
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        providesStreams = try? c.decodeIfPresent(Bool.self, forKey: .providesStreams)
        catalogs = try? c.decodeIfPresent([AddonCatalog].self, forKey: .catalogs)
    }
}

enum AddonError: LocalizedError {
    case invalidAddress, noStreams

    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "That isn't an addon address. Paste the link that ends in manifest.json."
        case .noStreams: return "This addon offers neither streams nor catalogues of films and series."
        }
    }
}

enum Addons {
    /// Fetches the manifest at a pasted address (https://… or stremio://…) and describes the addon.
    static func install(from text: String) async throws -> StreamAddon {
        var address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.hasPrefix("stremio://") { address = "https://" + address.dropFirst("stremio://".count) }
        if address.hasSuffix("/") { address.removeLast() }
        if address.hasSuffix("/manifest.json") { address.removeLast("/manifest.json".count) }
        guard let manifestURL = URL(string: address + "/manifest.json"), manifestURL.scheme?.hasPrefix("http") == true else {
            throw AddonError.invalidAddress
        }
        let manifest = try await HTTP.get(manifestURL, as: Manifest.self)
        let catalogs = manifest.browsableCatalogs
        guard manifest.providesStreams || !catalogs.isEmpty else { throw AddonError.noStreams }
        return StreamAddon(id: manifest.id, name: manifest.name, base: address, types: manifest.streamTypes,
                           providesStreams: manifest.providesStreams, catalogs: catalogs)
    }

    /// A page of an addon's catalogue. Only titles with an IMDb id are kept: title pages and
    /// Torrentio both work by IMDb id.
    static func catalog(_ catalog: AddonCatalog, from addon: StreamAddon, page: Int = 0) async throws -> [MediaItem] {
        let id = catalog.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? catalog.id
        let skip = page > 0 ? "/skip=\(page * 100)" : ""
        let url = try HTTP.url("\(addon.base)/catalog/\(catalog.type)/\(id)\(skip).json")
        return try await Cinemeta.items(at: url, fallbackKind: catalog.kind ?? .movie)
    }

    static func streams(from addon: StreamAddon, kind: MediaKind, videoID: String) async throws -> [StreamSource] {
        let id = videoID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/:"))) ?? videoID
        let url = try HTTP.url("\(addon.base)/stream/\(kind.rawValue)/\(id).json")
        return try await StremioStreams.fetch(url, addon: addon.name)
    }

    private struct Manifest: Decodable {
        let id: String
        let name: String
        let types: [String]
        let resources: [Resource]
        let catalogs: [Catalog]

        struct Catalog: Decodable {
            let type: String
            let id: String
            let name: String?
            let extra: [Extra]?
            let extraRequired: [String]?

            struct Extra: Decodable {
                let name: String
                let isRequired: Bool?
            }

            /// Listable without typing anything: no required search, genre or skip.
            var browsable: Bool {
                (extra ?? []).allSatisfy { $0.isRequired != true } && (extraRequired ?? []).isEmpty
            }
        }

        struct Resource: Decodable {
            let name: String
            let types: [String]?
            init(from decoder: Decoder) throws {
                if let single = try? decoder.singleValueContainer().decode(String.self) {
                    name = single
                    types = nil
                } else {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    name = try container.decode(String.self, forKey: .name)
                    types = try? container.decode([String].self, forKey: .types)
                }
            }
            enum CodingKeys: String, CodingKey { case name, types }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? container.decode(String.self, forKey: .id)) ?? UUID().uuidString
            name = (try? container.decode(String.self, forKey: .name)) ?? "Addon"
            types = (try? container.decode([String].self, forKey: .types)) ?? []
            resources = (try? container.decode([Resource].self, forKey: .resources)) ?? []
            catalogs = (try? container.decode([Lossy<Catalog>].self, forKey: .catalogs))?.compactMap(\.value) ?? []
        }
        enum CodingKeys: String, CodingKey { case id, name, types, resources, catalogs }

        var browsableCatalogs: [AddonCatalog] {
            catalogs.filter { $0.browsable && MediaKind(rawValue: $0.type) != nil }
                .map { AddonCatalog(id: $0.id, type: $0.type, name: $0.name ?? $0.id) }
        }

        var providesStreams: Bool { resources.contains { $0.name == "stream" } }
        var streamTypes: [String] { resources.first { $0.name == "stream" }?.types ?? types }
    }
}

// MARK: - Finding sources

/// What a source search needs from the settings, copied so it can run off the main actor.
struct SourceQuery: Sendable, Equatable {
    var torrentio: TorrentioConfig
    var addons: [StreamAddon]
    /// A second debrid service, searched alongside the first; its releases fill in what the first
    /// hasn't cached.
    var secondary: TorrentioConfig?

    init(torrentio: TorrentioConfig, addons: [StreamAddon], secondary: TorrentioConfig? = nil) {
        self.torrentio = torrentio
        self.addons = addons
        self.secondary = secondary
    }
}

enum SourceFinder {
    /// Torrentio and every enabled addon at once, merged. One addon failing or timing out never
    /// hides the others' results; only when every one of them fails is that an error.
    static func find(kind: MediaKind, videoID: String, query: SourceQuery) async throws -> [StreamSource] {
        let addons = query.addons.filter { $0.enabled && $0.hasStreams && $0.supports(kind) }
        var results: [Int: [StreamSource]] = [:]
        var firstError: Error?
        await withTaskGroup(of: (Int, Result<[StreamSource], Error>).self) { group in
            group.addTask {
                do { return (0, .success(try await Torrentio.streams(kind: kind, videoID: videoID, config: query.torrentio))) }
                catch { return (0, .failure(error)) }
            }
            // The second service comes right after the first, ahead of the addons: the merge keeps
            // the first copy of a file, and a cached copy replaces one that isn't.
            if let secondary = query.secondary, secondary.hasDebrid {
                group.addTask {
                    do {
                        let label = "Torrentio · \(secondary.service.name)"
                        return (1, .success(try await Torrentio.streams(kind: kind, videoID: videoID, config: secondary, label: label)))
                    } catch {
                        return (1, .failure(error))
                    }
                }
            }
            for (offset, addon) in addons.enumerated() {
                group.addTask {
                    do {
                        let streams = try await withTimeout(seconds: 20) {
                            try await Addons.streams(from: addon, kind: kind, videoID: videoID)
                        }
                        return (offset + 2, .success(streams))
                    } catch {
                        return (offset + 2, .failure(error))
                    }
                }
            }
            for await (slot, result) in group {
                switch result {
                case let .success(streams): results[slot] = streams
                case let .failure(error): if firstError == nil { firstError = error }
                }
            }
        }
        if results.isEmpty, let firstError { throw firstError }
        return merge(results.keys.sorted().compactMap { results[$0] }).filter { passes($0, query.torrentio) }
    }

    /// Torrentio applies the quality, size and cache filters itself; other addons know nothing of
    /// them, so the same rules are applied here to everything.
    static func passes(_ source: StreamSource, _ config: TorrentioConfig) -> Bool {
        let excluded = Set(config.excludedQualities)
        switch source.quality {
        case "4K": if excluded.contains("4k") { return false }
        case "1080p", "720p", "480p": if excluded.contains(source.quality) { return false }
        case "CAM": if excluded.contains("cam") || excluded.contains("scr") { return false }
        case "Other": if excluded.contains("unknown") { return false }
        default: break
        }
        if excluded.contains("dolbyvision") && source.hasDolbyVision { return false }
        if excluded.contains("hdrall") && source.hasHDR { return false }
        if excluded.contains("threed") && source.tags.contains("3D") { return false }
        if config.maxSizeGB > 0, source.sizeBytes > Double(config.maxSizeGB) * 1_073_741_824 { return false }
        if config.cachedOnly && config.hasDebrid && !source.isCached { return false }
        if config.minSeeders > 0, !source.isCached, let seeders = source.seeders, seeders < config.minSeeders { return false }
        return true
    }

    /// Keeps the first copy of each file (Torrentio's, then addons in the order they were added),
    /// but a cached copy from a later addon replaces an uncached one.
    static func merge(_ lists: [[StreamSource]]) -> [StreamSource] {
        var order: [String] = []
        var byKey: [String: StreamSource] = [:]
        for list in lists {
            for source in list {
                let key = source.fileKey
                if let existing = byKey[key] {
                    if !existing.isCached && source.isCached && source.isPlayable { byKey[key] = source }
                } else {
                    byKey[key] = source
                    order.append(key)
                }
            }
        }
        return order.compactMap { byKey[$0] }
    }
}

struct TimeoutError: LocalizedError {
    var errorDescription: String? { "The addon took too long to answer." }
}

func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        guard let first = try await group.next() else { throw TimeoutError() }
        group.cancelAll()
        return first
    }
}

// MARK: - Patterns

/// The release-name patterns, compiled once: parsing a search runs them hundreds of times.
enum Pattern {
    static let videoExtensionAtEnd = make(#"\.(mkv|mp4|avi|m4v|ts|webm)$"#)
    static let videoExtension = make(#"\.(mkv|mp4|avi|m4v|ts|m2ts|webm)\b"#)
    static let releaseGroup = make(#"-([A-Za-z0-9]{2,20})(?:\[[^\]]*\])?$"#, caseInsensitive: false)
    static let size = make(#"💾\s*([\d.,]+\s*[KMGT]?B)"#)
    static let seeders = make(#"👤\s*(\d+)"#)
    static let providerGear = make(#"⚙️\s*([^💾👤🔎]+)"#)
    static let providerSearch = make(#"🔎\s*([^💾👤⚙️]+)"#)
    static let uhd = make(#"\b(2160p|4k|uhd)\b"#)
    static let cam = make(#"\b(cam|camrip|hdcam|ts|hdts|tsrip|telesync)\b"#)
    static let dolbyVision = make(#"\b(dv|dovi|dolby[ .]?vision)\b"#)
    static let hdr10Plus = make(#"hdr10(\+|plus)"#)
    static let hdr = make(#"\bhdr(10)?\b"#)
    static let hlg = make(#"\bhlg\b"#)
    static let remux = make(#"\bremux\b"#)
    static let hevc = make(#"\b(x265|hevc|h\.?265)\b"#)
    static let av1 = make(#"\bav1\b"#)
    static let threeD = make(#"\b(3d|h-?sbs|half[ .-]?sbs|h-?ou|half[ .-]?ou)\b"#)

    static func make(_ pattern: String, caseInsensitive: Bool = true) -> NSRegularExpression {
        // The patterns are constants; a typo is a programming error caught by the tests.
        try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }
}

extension NSRegularExpression {
    func matches(_ text: String) -> Bool {
        firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The first capture group of the first match.
    func firstGroup(in text: String) -> String? {
        guard let match = firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    func replacing(in text: String, with template: String) -> String {
        stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}

/// Runs async work and captures its outcome, so two requests can run side by side and each
/// failure be looked at on its own.
func asyncResult<T>(_ work: () async throws -> T) async -> Result<T, Error> {
    do { return .success(try await work()) } catch { return .failure(error) }
}
