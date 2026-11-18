import Foundation

/// Subtitles from OpenSubtitles through its public Stremio addon, which needs no account or key.
/// Used when a file carries nothing in the reader's language.
enum OnlineSubtitles {
    static let base = "https://opensubtitles-v3.strem.io"

    struct Result: Identifiable, Hashable {
        let id: String
        let url: URL
        let language: String   // ISO 639-2, e.g. "eng"
    }

    static func search(kind: MediaKind, videoID: String, filename: String?, size: Double?) async throws -> [Result] {
        let id = videoID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/:"))) ?? videoID
        var extras: [String] = []
        if let filename, !filename.isEmpty { extras.append("filename=\(HTTP.pathValue(filename))") }
        if let size, size > 0 { extras.append("videoSize=\(Int64(size))") }
        let extra = extras.isEmpty ? "" : "/" + extras.joined(separator: "&")
        let url = try HTTP.url("\(base)/subtitles/\(kind.rawValue)/\(id)\(extra).json")
        let response = try await HTTP.get(url, as: Response.self)
        var seen = Set<String>()
        return response.subtitles.compactMap { raw in
            guard let link = URL(string: raw.url), seen.insert(raw.url).inserted else { return nil }
            return Result(id: raw.id ?? raw.url, url: link, language: raw.lang.lowercased())
        }
    }

    private struct Response: Decodable {
        let subtitles: [Raw]
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            subtitles = (try? container.decode([Raw].self, forKey: .subtitles)) ?? []
        }
        enum CodingKeys: String, CodingKey { case subtitles }
    }

    private struct Raw: Decodable {
        let id: String?
        let url: String
        let lang: String
    }
}
