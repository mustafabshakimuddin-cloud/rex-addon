import Foundation
import Testing
@testable import Reel

@MainActor
struct LibraryTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("library-\(UUID().uuidString).json")
    }

    private let show = MediaItem(id: "tt0000001", kind: .series, name: "Show")

    private func episode(_ season: Int, _ number: Int, aired: Bool = true) -> Episode {
        Episode(id: "tt0000001:\(season):\(number)", season: season, number: number, title: "E\(number)",
                released: aired ? Date().addingTimeInterval(-86_400 * Double(100 - number)) : Date().addingTimeInterval(86_400 * 5))
    }

    private var detail: MediaDetail {
        MediaDetail(item: show, episodes: [episode(1, 1), episode(1, 2), episode(1, 3, aired: false)])
    }

    @Test func unreadableFileIsKeptAside() throws {
        let url = tempURL()
        try Data("{ not json".utf8).write(to: url)
        let library = Library(fileURL: url)
        #expect(library.watchlist.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let folder = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        #expect(folder.contains { $0.lastPathComponent.hasPrefix(url.deletingPathExtension().lastPathComponent + ".unreadable-") })
    }

    @Test func roundTrip() throws {
        let url = tempURL()
        let library = Library(fileURL: url)
        library.toggleWatchlist(show)
        library.record(PlaybackTarget(item: show, episode: episode(1, 1)), position: 600, duration: 1200)
        library.saveNow()
        library.waitForSave()
        let again = Library(fileURL: url)
        #expect(again.watchlist.map(\.id) == [show.id])
        #expect(again.resumePosition(for: PlaybackTarget(item: show, episode: episode(1, 1))) == 600)
    }

    @Test func oneBadEntryOnlyCostsItself() throws {
        let url = tempURL()
        let json = """
        {"watchlist":[{"id":"tt1","kind":"movie","name":"Good","genres":[]},{"id":"tt2","kind":"opera","name":"Bad","genres":[]}],"progress":{}}
        """
        try Data(json.utf8).write(to: url)
        let library = Library(fileURL: url)
        #expect(library.watchlist.map(\.id) == ["tt1"])
    }

    @Test func neverOffersAnUnairedEpisode() {
        let library = Library(fileURL: tempURL())
        #expect(library.nextEpisode(in: detail)?.number == 1)
        library.markWatched([episode(1, 1), episode(1, 2)], of: show)
        #expect(library.nextEpisode(in: detail) == nil)
        let state = library.caughtUp(in: detail)
        #expect(state.caughtUp)
        #expect(state.nextAiring?.number == 3)
    }

    @Test func upNextAfterFinishing() {
        let library = Library(fileURL: tempURL())
        library.learnEpisodes(detail)
        library.record(PlaybackTarget(item: show, episode: episode(1, 1)), position: 1190, duration: 1200)
        let next = library.continueWatching.first
        #expect(next?.isUpNext == true)
        #expect(next?.episode?.number == 2)
        library.clearProgress(next!)
        #expect(library.continueWatching.isEmpty)
    }

    @Test func unwatchedStaysUnwatchedUntilTraktAgrees() {
        let library = Library(fileURL: tempURL())
        let id = episode(1, 1).id
        library.setExternalWatched(movies: [], episodes: [id])
        #expect(library.isWatched(episode(1, 1)))
        library.markUnwatched(PlaybackTarget(item: show, episode: episode(1, 1)))
        // Trakt hasn't heard yet and still lists it.
        library.setExternalWatched(movies: [], episodes: [id])
        #expect(!library.isWatched(episode(1, 1)))
        // Trakt dropped it, then it is watched elsewhere again: that counts.
        library.setExternalWatched(movies: [], episodes: [])
        library.setExternalWatched(movies: [], episodes: [id])
        #expect(library.isWatched(episode(1, 1)))
    }

    @Test func watchlistRemovalsElsewhereComeDown() {
        let library = Library(fileURL: tempURL())
        let film = MediaItem(id: "tt9", kind: .movie, name: "Film")
        library.applyTraktWatchlist([film, show])
        #expect(library.watchlist.count == 2)
        library.applyTraktWatchlist([show])
        #expect(library.watchlist.map(\.id) == [show.id])
        // Removed here but not yet sent: Trakt's copy doesn't bring it back.
        library.toggleWatchlist(show)
        library.applyTraktWatchlist([show], pendingRemovals: [show.id])
        #expect(library.watchlist.isEmpty)
    }

    @Test func furthestEpisodeAcrossSources() {
        let library = Library(fileURL: tempURL())
        library.setExternalWatched(movies: [], episodes: ["tt0000001:2:4", "tt0000002:1:1"])
        library.record(PlaybackTarget(item: show, episode: episode(1, 9)), position: 100, duration: 1000)
        #expect(library.furthestEpisode(inSeries: show.id) ?? (0, 0) == (2, 4))
    }
}

@MainActor
struct ListsTests {
    @Test func listsKeepTheirTitles() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lists-\(UUID().uuidString).json")
        let store = ListsStore(fileURL: url)
        let film = MediaItem(id: "tt1", kind: .movie, name: "Film")
        let list = store.create("  Weekend  ", with: film)
        #expect(store.list(list.id)?.name == "Weekend")
        #expect(store.contains(film, in: list.id))
        store.toggle(film, in: list.id)
        #expect(!store.contains(film, in: list.id))
        store.toggle(film, in: list.id)
        store.saveNow()
        Thread.sleep(forTimeInterval: 0.3)
        let again = ListsStore(fileURL: url)
        #expect(again.lists(containing: film).map(\.name) == ["Weekend"])
    }
}

@MainActor
struct ProfileTests {
    @Test func defaultProfileKeepsOldFileNames() {
        let me = Profile(id: Profile.defaultID, name: "Me", symbol: "person.fill")
        #expect(me.file("library").lastPathComponent == "library.json")
        #expect(me.key("trakt.token") == "trakt.token")
        let kid = Profile(id: "abc", name: "Kid", symbol: "star.fill", isKids: true)
        #expect(kid.file("library").lastPathComponent == "library-abc.json")
        #expect(kid.key("player.choices") == "player.choices.abc")
    }

    @Test func kidsSeeFamilyAndAnimationOnly() {
        let library = Library(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("k-\(UUID().uuidString).json"))
        let items = [MediaItem(id: "tt1", kind: .movie, name: "Cartoon", genres: ["Animation"]),
                     MediaItem(id: "tt2", kind: .movie, name: "Slasher", genres: ["Horror"])]
        library.kidsOnly = true
        #expect(library.shown(items, hidingWatched: false).map(\.id) == ["tt1"])
    }

    @Test func switchingLoadsAnotherLibrary() {
        let first = FileManager.default.temporaryDirectory.appendingPathComponent("a-\(UUID().uuidString).json")
        let second = FileManager.default.temporaryDirectory.appendingPathComponent("b-\(UUID().uuidString).json")
        let library = Library(fileURL: first)
        library.toggleWatchlist(MediaItem(id: "tt1", kind: .movie, name: "Film"))
        library.load(from: second)
        #expect(library.watchlist.isEmpty)
        library.load(from: first)
        library.waitForSave()
        #expect(library.watchlist.map(\.id) == ["tt1"])
    }
}
