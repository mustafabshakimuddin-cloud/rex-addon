package community.reel.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.time.Duration

class LibraryTests {
    private lateinit var folder: File
    @Before fun setUp() { folder = freshPlatform() }

    private fun temp(name: String = "library") = File(folder, "$name-${java.util.UUID.randomUUID()}.json")

    private val show = MediaItem(id = "tt0000001", kind = MediaKind.SERIES, name = "Show")

    private fun episode(season: Int, number: Int, aired: Boolean = true) = Episode(
        "tt0000001:$season:$number", season, number, "E$number",
        released = if (aired) now().minus(Duration.ofDays(100L - number)) else now().plus(Duration.ofDays(5)),
    )

    private val detail get() = MediaDetail(show, episodes = listOf(episode(1, 1), episode(1, 2), episode(1, 3, aired = false)))

    @Test fun unreadableFileIsKeptAside() {
        val file = temp()
        file.writeText("{ not json")
        val library = Library(file)
        assertTrue(library.watchlist.isEmpty())
        assertFalse(file.exists())
        assertTrue(folder.listFiles()!!.any { it.name.startsWith(file.nameWithoutExtension + ".unreadable-") })
    }

    @Test fun roundTrip() {
        val file = temp()
        val library = Library(file)
        library.toggleWatchlist(show)
        library.record(PlaybackTarget(show, episode(1, 1)), 600.0, 1200.0)
        library.saveNow()
        library.waitForSave()
        val again = Library(file)
        assertEquals(listOf(show.id), again.watchlist.map { it.id })
        assertEquals(600.0, again.resumePosition(PlaybackTarget(show, episode(1, 1))))
    }

    @Test fun oneBadEntryOnlyCostsItself() {
        val file = temp()
        file.writeText("""{"watchlist":[{"id":"tt1","kind":"movie","name":"Good","genres":[]},{"id":"tt2","kind":"opera","name":"Bad","genres":[]}],"progress":{}}""")
        assertEquals(listOf("tt1"), Library(file).watchlist.map { it.id })
    }

    @Test fun neverOffersAnUnairedEpisode() {
        val library = Library(temp())
        assertEquals(1, library.nextEpisode(detail)?.number)
        library.markWatched(listOf(episode(1, 1), episode(1, 2)), show)
        assertNull(library.nextEpisode(detail))
        val (caughtUp, nextAiring) = library.caughtUp(detail)
        assertTrue(caughtUp)
        assertEquals(3, nextAiring?.number)
    }

    @Test fun upNextAfterFinishing() {
        val library = Library(temp())
        library.learnEpisodes(detail)
        library.record(PlaybackTarget(show, episode(1, 1)), 1190.0, 1200.0)
        val next = library.continueWatching.first()
        assertTrue(next.isUpNext)
        assertEquals(2, next.episode?.number)
        library.clearProgress(next)
        assertTrue(library.continueWatching.isEmpty())
    }

    @Test fun unwatchedStaysUnwatchedUntilTraktAgrees() {
        val library = Library(temp())
        val id = episode(1, 1).id
        library.setExternalWatched(emptySet(), setOf(id))
        assertTrue(library.isWatched(episode(1, 1)))
        library.markUnwatched(PlaybackTarget(show, episode(1, 1)))
        // Trakt hasn't heard yet and still lists it.
        library.setExternalWatched(emptySet(), setOf(id))
        assertFalse(library.isWatched(episode(1, 1)))
        // Trakt dropped it, then it is watched elsewhere again: that counts.
        library.setExternalWatched(emptySet(), emptySet())
        library.setExternalWatched(emptySet(), setOf(id))
        assertTrue(library.isWatched(episode(1, 1)))
    }

    @Test fun watchlistRemovalsElsewhereComeDown() {
        val library = Library(temp())
        val film = MediaItem(id = "tt9", kind = MediaKind.MOVIE, name = "Film")
        library.applyTraktWatchlist(listOf(film, show))
        assertEquals(2, library.watchlist.size)
        library.applyTraktWatchlist(listOf(show))
        assertEquals(listOf(show.id), library.watchlist.map { it.id })
        // Removed here but not yet sent: Trakt's copy doesn't bring it back.
        library.toggleWatchlist(show)
        library.applyTraktWatchlist(listOf(show), pendingRemovals = setOf(show.id))
        assertTrue(library.watchlist.isEmpty())
    }

    @Test fun furthestEpisodeAcrossSources() {
        val library = Library(temp())
        library.setExternalWatched(emptySet(), setOf("tt0000001:2:4", "tt0000002:1:1"))
        library.record(PlaybackTarget(show, episode(1, 9)), 100.0, 1000.0)
        assertEquals(2 to 4, library.furthestEpisode(show.id))
    }

    @Test fun listsKeepTheirTitles() {
        val file = temp("lists")
        val store = ListsStore(file)
        val film = MediaItem(id = "tt1", kind = MediaKind.MOVIE, name = "Film")
        val list = store.create("  Weekend  ", film)
        assertEquals("Weekend", store.list(list.id)?.name)
        assertTrue(store.contains(film, list.id))
        store.toggle(film, list.id)
        assertFalse(store.contains(film, list.id))
        store.toggle(film, list.id)
        store.saveNow()
        store.waitForSave()
        assertEquals(listOf("Weekend"), ListsStore(file).listsContaining(film).map { it.name })
    }

    @Test fun defaultProfileKeepsOldFileNames() {
        val me = Profile(Profile.DEFAULT_ID, "Me", "person")
        assertEquals("library.json", me.file("library").name)
        assertEquals("trakt.token", me.key("trakt.token"))
        val kid = Profile("abc", "Kid", "star", isKids = true)
        assertEquals("library-abc.json", kid.file("library").name)
        assertEquals("player.choices.abc", kid.key("player.choices"))
    }

    @Test fun kidsSeeFamilyAndAnimationOnly() {
        val library = Library(temp())
        val items = listOf(MediaItem("tt1", MediaKind.MOVIE, "Cartoon", genres = listOf("Animation")),
            MediaItem("tt2", MediaKind.MOVIE, "Slasher", genres = listOf("Horror")))
        library.kidsOnly = true
        assertEquals(listOf("tt1"), library.shown(items, hidingWatched = false).map { it.id })
    }

    @Test fun switchingLoadsAnotherLibrary() {
        val first = temp("a")
        val second = temp("b")
        val library = Library(first)
        library.toggleWatchlist(MediaItem("tt1", MediaKind.MOVIE, "Film"))
        library.load(second)
        assertTrue(library.watchlist.isEmpty())
        library.load(first)
        library.waitForSave()
        assertEquals(listOf("tt1"), library.watchlist.map { it.id })
    }

    @Test fun settingsKeepTheirValues() {
        val settings = AppSettings()
        assertEquals(listOf("scr", "cam"), settings.excludedQualities)
        settings.maxSizeGB = 12
        settings.homeHidden = setOf(HomeSection.COMEDY)
        settings.debridKey = " key "
        val again = AppSettings()
        assertEquals(12, again.maxSizeGB)
        assertEquals(setOf(HomeSection.COMEDY), again.homeHidden)
        assertEquals("key", Platform.secrets.read("debrid.key"))
        assertFalse(HomeSection.COMEDY in again.visibleHomeSections)
    }

    @Test fun backupRoundTrip() {
        val library = Library(temp())
        val memory = SourceMemory(temp("sources"))
        library.toggleWatchlist(show)
        Platform.defaults.putString("torrentio.sort", "size")
        Platform.defaults.putString("unrelated", "x")
        val data = Backup.data(library, memory, null)
        val other = Library(temp())
        Platform.defaults.remove("torrentio.sort")
        Backup.restore(data, other, memory, null)
        assertEquals(listOf(show.id), other.watchlist.map { it.id })
        assertEquals("size", Platform.defaults.string("torrentio.sort"))
        assertFalse(data.contains("unrelated"))
    }
}
