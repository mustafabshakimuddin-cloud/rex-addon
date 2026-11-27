import Foundation

/// What is already in a debrid account, ready to stream: torrents (or items) and their video files.
/// Uses the same API key as Torrentio. Real-Debrid, AllDebrid, Premiumize and TorBox are read.
enum DebridCloud {
    struct Entry: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let bytes: Int64
        let added: Date?
        /// Files already known from the listing; empty when they are fetched on opening.
        var files: [File]
        /// Not finished on the service's side yet.
        var ready: Bool = true
    }

    struct File: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let bytes: Int64
        /// What the service needs to hand out a streaming link for this file.
        let handle: String
    }

    enum CloudError: LocalizedError {
        case unsupported, refused, noLink
        var errorDescription: String? {
            switch self {
            case .unsupported: return "This debrid service's files can't be listed here."
            case .refused: return "The debrid service refused the API key."
            case .noLink: return "The service didn't hand out a link for this file."
            }
        }
    }

    static func supports(_ service: DebridService) -> Bool {
        [.realdebrid, .alldebrid, .premiumize, .torbox].contains(service)
    }

    static let videoExtensions: Set<String> = ["mkv", "mp4", "m4v", "avi", "ts", "m2ts", "webm", "mov", "wmv"]

    static func isVideo(_ name: String) -> Bool {
        videoExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    // MARK: Listing

    static func list(service: DebridService, key: String) async throws -> [Entry] {
        switch service {
        case .realdebrid:
            let json = try await jsonArray(request("https://api.real-debrid.com/rest/1.0/torrents?limit=200", key: key))
            return json.compactMap { torrent in
                guard let id = torrent["id"] as? String else { return nil }
                let links = torrent["links"] as? [String] ?? []
                let status = torrent["status"] as? String
                return Entry(id: id, name: torrent["filename"] as? String ?? id, bytes: int64(torrent["bytes"]),
                             added: (torrent["added"] as? String).flatMap(DateParsing.parse), files: [],
                             ready: status == "downloaded" && !links.isEmpty)
            }
        case .torbox:
            let json = try await jsonObject(request("https://api.torbox.app/v1/api/torrents/mylist?bypass_cache=true", key: key))
            let items = json["data"] as? [[String: Any]] ?? []
            return items.compactMap { item in
                guard let id = item["id"].map({ "\($0)" }) else { return nil }
                let files = (item["files"] as? [[String: Any]] ?? []).compactMap { file -> File? in
                    guard let fileID = file["id"].map({ "\($0)" }) else { return nil }
                    let name = (file["short_name"] as? String) ?? (file["name"] as? String) ?? fileID
                    return File(id: fileID, name: name, bytes: int64(file["size"]), handle: "\(id):\(fileID)")
                }
                return Entry(id: id, name: item["name"] as? String ?? id, bytes: int64(item["size"]),
                             added: (item["created_at"] as? String).flatMap(DateParsing.parse), files: files,
                             ready: (item["download_finished"] as? Bool) ?? true)
            }
        case .premiumize:
            let json = try await jsonObject(request("https://www.premiumize.me/api/item/listall?apikey=\(encoded(key))", key: nil))
            if (json["status"] as? String) == "error" { throw CloudError.refused }
            // Premiumize lists files, not transfers: group them by their folder.
            let files = (json["files"] as? [[String: Any]] ?? []).compactMap { file -> (String, File)? in
                guard let id = file["id"] as? String, let name = file["name"] as? String else { return nil }
                let path = file["path"] as? String ?? name
                let folder = (path as NSString).deletingLastPathComponent
                return (folder.isEmpty ? name : folder, File(id: id, name: name, bytes: int64(file["size"]), handle: id))
            }
            return Dictionary(grouping: files, by: \.0).map { folder, group in
                Entry(id: folder, name: (folder as NSString).lastPathComponent, bytes: group.map(\.1.bytes).reduce(0, +),
                      added: nil, files: group.map(\.1))
            }
        case .alldebrid:
            var status = request("https://api.alldebrid.com/v4.1/magnet/status?agent=\(AppConfig.name)&apikey=\(encoded(key))", key: key)
            status.httpMethod = "POST"
            let json = try await jsonObject(status)
            if (json["status"] as? String) == "error" { throw CloudError.refused }
            let magnets = (json["data"] as? [String: Any])?["magnets"] as? [[String: Any]] ?? []
            return magnets.compactMap { magnet in
                guard let id = magnet["id"].map({ "\($0)" }) else { return nil }
                let added = (magnet["uploadDate"] as? Double).map { Date(timeIntervalSince1970: $0) }
                return Entry(id: id, name: magnet["filename"] as? String ?? id, bytes: int64(magnet["size"]), added: added,
                             files: [], ready: (magnet["statusCode"] as? Int).map { $0 == 4 } ?? true)
            }
        default:
            throw CloudError.unsupported
        }
    }

    /// The video files of one entry, fetched when it isn't in the listing already.
    static func files(of entry: Entry, service: DebridService, key: String) async throws -> [File] {
        if !entry.files.isEmpty { return entry.files.filter { isVideo($0.name) } }
        switch service {
        case .realdebrid:
            let info = try await jsonObject(request("https://api.real-debrid.com/rest/1.0/torrents/info/\(entry.id)", key: key))
            // Links follow the selected files in order.
            let links = info["links"] as? [String] ?? []
            let selected = (info["files"] as? [[String: Any]] ?? []).filter { ($0["selected"] as? Int) == 1 }
            return zip(selected, links).compactMap { file, link -> File? in
                let path = file["path"] as? String ?? ""
                let name = (path as NSString).lastPathComponent
                guard isVideo(name) else { return nil }
                return File(id: "\(file["id"] ?? link)", name: name, bytes: int64(file["bytes"]), handle: link)
            }
        case .alldebrid:
            var files = request("https://api.alldebrid.com/v4/magnet/files?agent=\(AppConfig.name)&apikey=\(encoded(key))&id[]=\(entry.id)", key: key)
            files.httpMethod = "POST"
            let json = try await jsonObject(files)
            let magnets = (json["data"] as? [String: Any])?["magnets"] as? [[String: Any]] ?? []
            var found: [File] = []
            // Files come as a tree: {n: name, s: size, l: link} or {n: folder, e: [children]}.
            func walk(_ nodes: [[String: Any]]) {
                for node in nodes {
                    if let children = node["e"] as? [[String: Any]] { walk(children); continue }
                    guard let name = node["n"] as? String, let link = node["l"] as? String, isVideo(name) else { continue }
                    found.append(File(id: link, name: name, bytes: int64(node["s"]), handle: link))
                }
            }
            for magnet in magnets { walk(magnet["files"] as? [[String: Any]] ?? []) }
            return found
        default:
            return []
        }
    }

    /// A direct, streamable address for a file. For Real-Debrid and AllDebrid this "unrestricts"
    /// the file's link; that is a read, it adds nothing to the account.
    static func link(for file: File, service: DebridService, key: String) async throws -> URL {
        switch service {
        case .realdebrid:
            var unrestrict = request("https://api.real-debrid.com/rest/1.0/unrestrict/link", key: key)
            unrestrict.httpMethod = "POST"
            unrestrict.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            unrestrict.httpBody = Data("link=\(encoded(file.handle))".utf8)
            let json = try await jsonObject(unrestrict)
            guard let text = json["download"] as? String, let url = URL(string: text) else { throw CloudError.noLink }
            return url
        case .torbox:
            let parts = file.handle.split(separator: ":")
            guard parts.count == 2 else { throw CloudError.noLink }
            let json = try await jsonObject(request(
                "https://api.torbox.app/v1/api/torrents/requestdl?token=\(encoded(key))&torrent_id=\(parts[0])&file_id=\(parts[1])", key: key))
            guard let text = json["data"] as? String, let url = URL(string: text) else { throw CloudError.noLink }
            return url
        case .premiumize:
            let json = try await jsonObject(request("https://www.premiumize.me/api/item/details?apikey=\(encoded(key))&id=\(encoded(file.handle))", key: nil))
            guard let text = (json["link"] as? String) ?? (json["stream_link"] as? String), let url = URL(string: text) else {
                throw CloudError.noLink
            }
            return url
        case .alldebrid:
            let json = try await jsonObject(request(
                "https://api.alldebrid.com/v4/link/unlock?agent=\(AppConfig.name)&apikey=\(encoded(key))&link=\(encoded(file.handle))", key: key))
            guard let text = (json["data"] as? [String: Any])?["link"] as? String, let url = URL(string: text) else { throw CloudError.noLink }
            return url
        default:
            throw CloudError.unsupported
        }
    }

    // MARK: Requests

    private static func request(_ address: String, key: String?) -> URLRequest {
        var request = URLRequest(url: URL(string: address)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        if let key { request.setValue("Bearer \(key.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization") }
        request.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func data(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await HTTP.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw CloudError.refused }
        guard (200..<300).contains(status) else { throw HTTPError.status(status, request.url!) }
        return data
    }

    private static func jsonObject(_ request: URLRequest) async throws -> [String: Any] {
        let body = try await data(request)
        guard !body.isEmpty else { return [:] }
        return (try JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }

    /// An account with nothing in it answers 204 with no body (Real-Debrid does): that is an empty
    /// list, not an error.
    private static func jsonArray(_ request: URLRequest) async throws -> [[String: Any]] {
        let body = try await data(request)
        guard !body.isEmpty else { return [] }
        return (try JSONSerialization.jsonObject(with: body)) as? [[String: Any]] ?? []
    }

    private static func encoded(_ text: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?/:")
        return text.trimmingCharacters(in: .whitespacesAndNewlines).addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    private static func int64(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) ?? 0 }
        return 0
    }
}
