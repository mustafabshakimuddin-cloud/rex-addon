import Foundation
import Testing
@testable import Reel

/// Release parsing: what a Stremio stream's free text says, pulled apart.
struct ParsingTests {
    private func stream(name: String, title: String, url: String? = "https://torrentio.strem.fun/resolve/realdebrid/KEY/abc/null/0/file.mkv",
                        hash: String? = "ABCDEF", index: Int? = 0) -> StreamSource? {
        var raw = StremioStreams.RawStream()
        raw.name = name
        raw.title = title
        raw.url = url
        raw.infoHash = hash
        raw.fileIdx = index
        return raw.source(index: 0, addon: "Torrentio", addonHost: "torrentio.strem.fun")
    }

    @Test func torrentioLine() throws {
        let source = try #require(stream(
            name: "[RD+] Torrentio\n4k DV | HDR",
            title: "Movie.2024.2160p.WEB-DL.DV.HDR.Atmos-FLUX\nMovie.2024.2160p.WEB-DL.DV.HDR.Atmos-FLUX.mkv\n👤 42 💾 18.3 GB ⚙️ TorrentGalaxy\n🇬🇧 / 🇫🇷"))
        #expect(source.quality == "4K")
        #expect(source.isCached)
        #expect(source.tags.contains("DV"))
        #expect(source.tags.contains("HDR"))
        #expect(source.tags.contains("Atmos"))
        #expect(source.seeders == 42)
        #expect(source.size == "18.3 GB")
        #expect(abs(source.sizeBytes - 18.3 * 1_073_741_824) < 1)
        #expect(source.provider == "TorrentGalaxy")
        #expect(source.releaseGroup == "FLUX")
        #expect(source.infoHash == "abcdef")
        #expect(source.needsResolve)
    }

    @Test func tsExtensionIsNotACam() throws {
        let source = try #require(stream(name: "[RD+] Comet", title: "Some.Show.S01E01.WEB.h264-GRP.ts"))
        #expect(source.quality == "Other")
        let cam = try #require(stream(name: "[RD+] Comet", title: "Movie.2025.HDTS.x264-GRP"))
        #expect(cam.quality == "CAM")
    }

    @Test func threeDAndCodecs() throws {
        let source = try #require(stream(name: "[RD+] Torrentio\n1080p", title: "Avatar.2009.1080p.3D.HSBS.BluRay.x265-GRP"))
        #expect(source.tags.contains("3D"))
        #expect(source.tags.contains("HEVC"))
        let plus = try #require(stream(name: "[RD+] Torrentio\n4k", title: "Movie.2160p.HDR10+.AV1-GRP"))
        #expect(plus.tags.contains("HDR10+"))
        #expect(plus.tags.contains("AV1"))
    }

    @Test func pathSegment() {
        var config = TorrentioConfig(service: .realdebrid, key: " KEY|= ", providers: ["yts"], excludedQualities: ["cam"],
                                     sort: .seeders, maxSizeGB: 10, cachedOnly: true)
        config.priorityLanguages = ["french", "german"]
        config.perQualityLimit = 5
        let segment = config.pathSegment
        #expect(segment.contains("providers=yts"))
        #expect(segment.contains("sort=seeders"))
        #expect(segment.contains("qualityfilter=cam"))
        #expect(segment.contains("sizefilter=10GB"))
        #expect(segment.contains("language=french,german"))
        #expect(segment.contains("limit=5"))
        #expect(segment.contains("debridoptions=nodownloadlinks"))
        #expect(segment.hasSuffix("realdebrid=KEY"))
    }

    @Test func serverAddress() {
        var config = TorrentioConfig()
        config.server = "https://my.torrentio.example/manifest.json"
        #expect(config.serverBase == "https://my.torrentio.example")
        config.server = "not a server"
        #expect(config.serverBase == Torrentio.base)
    }

    @Test func filters() throws {
        var config = TorrentioConfig(service: .realdebrid, key: "k", excludedQualities: ["threed"])
        let threeD = try #require(stream(name: "[RD+] Comet", title: "Film.2010.1080p.3D.SBS-X"))
        #expect(!SourceFinder.passes(threeD, config))
        config.excludedQualities = []
        config.cachedOnly = false
        config.minSeeders = 10
        let few = try #require(stream(name: "[RD download] Torrentio\n1080p", title: "Film.1080p-X\n👤 3 💾 2 GB"))
        #expect(!few.isCached)
        #expect(!SourceFinder.passes(few, config))
    }

    @Test func mergeKeepsCachedCopy() throws {
        let uncached = try #require(stream(name: "[RD download] Torrentio\n1080p", title: "Film.1080p-X"))
        var cached = try #require(stream(name: "[RD+] Comet", title: "Film.1080p-X"))
        cached.addon = "Comet"
        let merged = SourceFinder.merge([[uncached], [cached]])
        #expect(merged.count == 1)
        #expect(merged.first?.addon == "Comet")
    }

    @Test func errorVideos() throws {
        let denied = try #require(URL(string: "https://torrentio.strem.fun/videos/failed_access_v2.mp4"))
        #expect(ResolveError(errorVideo: denied) == .accessDenied)
        let selfHosted = try #require(URL(string: "https://my.host/videos/downloading_v2.mp4"))
        #expect(ResolveError(errorVideo: selfHosted) == .downloading)
        let file = try #require(URL(string: "https://download.real-debrid.com/d/ABC/videos/Film.mkv"))
        #expect(ResolveError(errorVideo: file) == nil)
    }

    @Test func redaction() {
        let text = "https://torrentio.strem.fun/realdebrid=SECRETKEY|sort=size/resolve/realdebrid/SECRETKEY/abc?apikey=SECRET2"
        let clean = Redact.text(text)
        #expect(!clean.contains("SECRETKEY"))
        #expect(!clean.contains("SECRET2"))
        #expect(Redact.text("Authorization: Bearer abc.def") == "Authorization: Bearer •••")
    }

    @Test func languages() {
        #expect(Languages.codes(for: "fre") == ["fr", "fre", "fra"])
        #expect(Languages.matches("de", preferred: "ger"))
        #expect(Languages.codes(for: "dut").contains("nl"))
        #expect(!Languages.searchTerms(for: "may").contains("may"))
        #expect(Languages.searchTerms(for: "ita").contains("italian"))
    }

    @Test func realDebridAccount() throws {
        let json: [String: Any] = ["username": "someone", "type": "premium", "expiration": "2030-01-02T03:04:05.000Z"]
        let info = try DebridAccount.parse(.realdebrid, json)
        #expect(info.username == "someone")
        #expect(info.premium == true)
        #expect(info.expires != nil)
        #expect(DebridAccount.supports(.realdebrid))
        #expect(!DebridAccount.supports(.offcloud))
    }
}
