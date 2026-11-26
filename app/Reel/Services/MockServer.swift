import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// `-ReelMock`: every request the app makes is answered here, from fixed data, so CI screenshots
/// show the same titles, sources and pictures on every run and never depend on Cinemeta, Torrentio
/// or the network being up. Not used otherwise.
final class MockServer: URLProtocol {
    static var isActive: Bool { ProcessInfo.processInfo.arguments.contains("-ReelMock") }

    override class func canInit(with request: URLRequest) -> Bool { isActive }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url ?? URL(string: "about:blank")!
        let (status, type, body) = Self.answer(for: url)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": type, "Cache-Control": "no-store"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    // MARK: Answers

    static func answer(for url: URL) -> (Int, String, Data) {
        let host = url.host ?? ""
        let path = url.path
        if host.contains("metahub") || host.contains("image.tmdb") || path.hasSuffix(".jpg") || path.hasSuffix(".png") {
            return (200, "image/png", picture(for: url.absoluteString))
        }
        if path.contains("/catalog/") && path.contains("calendar-videos") { return json(["metasDetailed": [seriesMeta(near: true)]]) }
        if path.contains("/catalog/") { return json(["metas": catalog(series: path.contains("/series/"))]) }
        if path.contains("/meta/") { return json(["meta": path.contains("/series/") ? seriesMeta(near: false) : filmMeta()]) }
        if path.contains("/stream/") { return json(["streams": streams]) }
        if path.contains("/subtitles/") { return json(["subtitles": [] as [Any]]) }
        if path.hasSuffix("manifest.json") { return json(["id": "mock", "name": "Mock", "resources": ["stream"], "types": ["movie", "series"]]) }
        return (404, "application/json", Data("{}".utf8))
    }

    private static func json(_ object: Any) -> (Int, String, Data) {
        (200, "application/json", (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    private static let genres = [["Drama", "Mystery"], ["Comedy", "Family"], ["Action", "Sci-Fi"], ["Animation", "Family"], ["Crime", "Thriller"]]

    private static func catalog(series: Bool) -> [[String: Any]] {
        (1...12).map { index in
            let id = String(format: "tt99%05d", index + (series ? 500 : 0))
            return ["id": id, "imdb_id": id, "type": series ? "series" : "movie",
                    "name": series ? "Sample Series \(index)" : "Sample Film \(index)",
                    "poster": "https://images.metahub.space/poster/small/\(id)/img",
                    "background": "https://images.metahub.space/background/medium/\(id)/img",
                    "releaseInfo": series ? "\(2015 + index % 10)–" : "\(2010 + index)",
                    "imdbRating": String(format: "%.1f", 6.0 + Double(index % 4) * 0.8),
                    "genres": genres[index % genres.count],
                    "description": "A placeholder title for screenshots. Nothing here is real."] as [String: Any]
        }
    }

    private static func filmMeta() -> [String: Any] {
        var meta = catalog(series: false)[0]
        meta["runtime"] = "1h 52min"
        meta["cast"] = ["Alex Example", "Sam Sample", "Jo Placeholder"]
        meta["director"] = ["Dee Rector"]
        return meta
    }

    /// The screenshot tour opens tt0903747; any series id gets this, episodes dated around today.
    private static func seriesMeta(near: Bool) -> [String: Any] {
        let day = 86_400.0
        let videos: [[String: Any]] = (1...2).flatMap { season in
            (1...8).map { number in
                let offset = Double((season - 1) * 8 + number - 12) * 7 * day
                return ["id": "tt0903747:\(season):\(number)", "season": season, "episode": number,
                        "name": "Chapter \(number)", "overview": "An episode description for screenshots.",
                        "thumbnail": "https://images.metahub.space/background/small/ep\(season)\(number)/img",
                        "released": ISO8601DateFormatter().string(from: Date().addingTimeInterval(offset))] as [String: Any]
            }
        }
        return ["id": "tt0903747", "type": "series", "name": "Breaking Bad",
                "poster": "https://images.metahub.space/poster/medium/tt0903747/img",
                "background": "https://images.metahub.space/background/large/tt0903747/img",
                "releaseInfo": "2008–2013", "imdbRating": "9.5", "genres": ["Crime", "Drama"],
                "description": "A placeholder series for screenshots.", "runtime": "49 min",
                "cast": ["Alex Example", "Sam Sample"], "director": [], "videos": videos]
    }

    private static let streams: [[String: Any]] = [
        ["name": "[RD+] Torrentio\n4k DV | HDR", "title": "Sample.2160p.WEB-DL.DV.HDR.Atmos-GRP\n👤 120 💾 18.2 GB ⚙️ Mock\n🇬🇧",
         "url": "https://example.invalid/4k.mkv", "infoHash": "aaaa", "fileIdx": 0],
        ["name": "[RD+] Torrentio\n1080p", "title": "Sample.1080p.BluRay.x265-GRP\n👤 340 💾 4.1 GB ⚙️ Mock\n🇬🇧",
         "url": "https://example.invalid/1080.mkv", "infoHash": "bbbb", "fileIdx": 0],
        ["name": "[RD download] Torrentio\n720p", "title": "Sample.720p.WEB-DL-GRP\n👤 55 💾 1.2 GB ⚙️ Mock",
         "url": "https://example.invalid/720.mkv", "infoHash": "cccc", "fileIdx": 0],
    ]

    /// A soft gradient picked from the address, so each title gets its own colour.
    private static func picture(for key: String) -> Data {
        #if canImport(UIKit)
        // Swift's hashValue changes every launch; this sum doesn't, so pictures match between runs.
        let hue = CGFloat(key.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
        let size = CGSize(width: 300, height: 450)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor(hue: hue, saturation: 0.55, brightness: 0.55, alpha: 1).cgColor,
                          UIColor(hue: hue, saturation: 0.7, brightness: 0.2, alpha: 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
        }
        return image.pngData() ?? Data()
        #else
        return Data()
        #endif
    }
}
