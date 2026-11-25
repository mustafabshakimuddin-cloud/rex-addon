import Foundation

enum HTTPError: LocalizedError {
    case status(Int, URL)
    case invalidURL(String)

    var errorDescription: String? {
        switch self {
        case let .status(code, url): return "The server \(url.host ?? "") answered \(code)."
        case .invalidURL: return "That address isn't valid."
        }
    }
}

enum HTTP {
    /// "Reel/0.1.42", with the build's real version.
    static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "\(AppConfig.name)/\(version)"
    }()

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.requestCachePolicy = .useProtocolCachePolicy
        config.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 128 << 20)
        config.httpAdditionalHeaders = ["Accept": "application/json", "User-Agent": userAgent]
        return URLSession(configuration: config)
    }()

    static let decoder = JSONDecoder()

    /// A GET with up to two retries for the failures that usually pass: a dropped connection, a
    /// timeout, a 429 or a 5xx. Anything else, and cancellation, fails straight away.
    static func get<T: Decodable>(_ url: URL, as type: T.Type = T.self, retries: Int = 2) async throws -> T {
        var attempt = 0
        while true {
            do {
                let (data, response) = try await session.data(from: url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw HTTPError.status(http.statusCode, url)
                }
                return try decoder.decode(T.self, from: data)
            } catch {
                guard attempt < retries, isTransient(error) else { throw error }
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(attempt) * 700_000_000)
            }
        }
    }

    static func isTransient(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if case let HTTPError.status(code, _) = error { return code == 429 || (500..<600).contains(code) }
        guard let url = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed, .cannotFindHost].contains(url.code)
    }

    /// Whether an error means the device has no usable network, rather than that a server or a
    /// source is at fault.
    static func isOffline(_ error: Error) -> Bool {
        guard let url = error as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
                .timedOut, .cannotConnectToHost, .dnsLookupFailed, .cannotFindHost, .callIsActive].contains(url.code)
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

/// Removes credentials from text that may be shown or shared: Torrentio paths carry the debrid
/// key (`realdebrid=KEY`), resolve links carry it as a path segment, and some services take it
/// as `apikey=`.
enum Redact {
    private static let patterns: [(NSRegularExpression, String)] = [
        (Pattern.make(#"((?:realdebrid|alldebrid|premiumize|torbox|debridlink|easydebrid|offcloud|putio)(?:=|%3D))[^|/%&\s]+"#), "$1•••"),
        (Pattern.make(#"(/resolve/[a-z]+/)[^/\s]+"#), "$1•••"),
        (Pattern.make(#"((?:apikey|api_key|token|key)=)[^&\s]+"#), "$1•••"),
        (Pattern.make(#"(Bearer\s+)[A-Za-z0-9._-]+"#), "$1•••"),
    ]

    static func text(_ text: String) -> String {
        patterns.reduce(text) { $1.0.replacing(in: $0, with: $1.1) }
    }
}
