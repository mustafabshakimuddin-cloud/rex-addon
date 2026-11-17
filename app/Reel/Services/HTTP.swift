import Foundation

enum HTTPError: LocalizedError {
    case status(Int, URL)
    case invalidURL(String)

    var errorDescription: String? {
        switch self {
        case let .status(code, url): return "The server \(url.host ?? "") answered \(code)."
        case let .invalidURL(text): return "Invalid address: \(text)"
        }
    }
}

enum HTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.requestCachePolicy = .useProtocolCachePolicy
        config.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 128 << 20)
        config.httpAdditionalHeaders = ["Accept": "application/json", "User-Agent": "\(AppConfig.name)/1.0"]
        return URLSession(configuration: config)
    }()

    static let decoder = JSONDecoder()

    static func get<T: Decodable>(_ url: URL, as type: T.Type = T.self) async throws -> T {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPError.status(http.statusCode, url)
        }
        return try decoder.decode(T.self, from: data)
    }

    static func url(_ text: String) throws -> URL {
        guard let url = URL(string: text) else { throw HTTPError.invalidURL(text) }
        return url
    }

    /// Percent-encodes a value for use inside a Stremio-style path segment (`genre=Sci-Fi`).
    static func pathValue(_ text: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?&=#%")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}
