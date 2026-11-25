import Foundation
import Testing
@testable import Reel

@MainActor
struct RankingTests {
    private func source(_ id: String, quality: String = "1080p", tags: [String] = [], cached: Bool = true,
                        release: String? = nil) -> StreamSource {
        StreamSource(id: id, addon: "Torrentio", addonHost: nil, quality: quality, tags: tags, release: release ?? "Film.\(id)-GRP",
                     file: nil, size: nil, sizeBytes: 0, seeders: nil, provider: nil, languages: nil, debridTag: nil,
                     cached: cached, url: URL(string: "https://example.com/\(id)"), infoHash: id, fileIndex: 0, bingeGroup: nil)
    }

    private func memory() -> SourceMemory {
        SourceMemory(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("sources-\(UUID().uuidString).json"))
    }

    @Test func cachedThenQualityThenPreference() {
        let sources = [source("a", quality: "720p"), source("b", cached: false), source("c"), source("d", tags: ["HDR"])]
        var preferences = SourcePreferences.none
        preferences.hdr = .prefer
        let ranked = SourceRanker.rank(sources, memory: memory(), preferences: preferences).map(\.id)
        #expect(ranked == ["d", "c", "a", "b"])
    }

    @Test func failedSourcesGoLast() {
        let store = memory()
        let bad = source("bad")
        store.noteFailure(bad, reason: "nope")
        let ranked = SourceRanker.rank([bad, source("ok", quality: "480p")], memory: store).map(\.id)
        #expect(ranked == ["ok", "bad"])
    }

    @Test func deviceMatching() {
        var preferences = SourcePreferences()
        preferences.device = .init(hdr: false, dolbyVision: false, av1: false)
        let ranked = SourceRanker.rank([source("dv", tags: ["DV", "HDR"]), source("av1", tags: ["AV1"]), source("plain")],
                                       memory: memory(), preferences: preferences).map(\.id)
        #expect(ranked.first == "plain")
        #expect(ranked.last == "av1")
    }

    @Test func preferredGroupAndLanguage() {
        var preferences = SourcePreferences.none
        preferences.groups = ["FLUX"]
        let ranked = SourceRanker.rank([source("x", release: "Film.1080p-OTHER"), source("y", release: "Film.1080p-FLUX")],
                                       memory: memory(), preferences: preferences).map(\.id)
        #expect(ranked == ["y", "x"])
        var italian = SourcePreferences.none
        italian.audioLanguage = "ita"
        let byLanguage = SourceRanker.rank([source("en", release: "Film.1080p.ENG-X"), source("it", release: "Film.1080p.ITA.ENG-X")],
                                           memory: memory(), preferences: italian).map(\.id)
        #expect(byLanguage == ["it", "en"])
    }
}
