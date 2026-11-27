package community.reel.core

import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import java.io.File

class RankingTests {
    private lateinit var folder: File
    @Before fun setUp() { folder = freshPlatform() }

    private fun source(id: String, quality: String = "1080p", tags: List<String> = emptyList(), cached: Boolean = true, release: String? = null) =
        StreamSource(id = id, addon = "Torrentio", quality = quality, tags = tags, release = release ?: "Film.$id-GRP",
            cached = cached, url = "https://example.com/$id", infoHash = id, fileIndex = 0)

    private fun memory() = SourceMemory(File(folder, "sources-${java.util.UUID.randomUUID()}.json"))

    @Test fun cachedThenQualityThenPreference() {
        val sources = listOf(source("a", quality = "720p"), source("b", cached = false), source("c"), source("d", tags = listOf("HDR")))
        val ranked = SourceRanker.rank(sources, memory(), preferences = SourcePreferences.none.copy(hdr = Leaning.PREFER)).map { it.id }
        assertEquals(listOf("d", "c", "a", "b"), ranked)
    }

    @Test fun failedSourcesGoLast() {
        val store = memory()
        val bad = source("bad")
        store.noteFailure(bad, "nope")
        assertEquals(listOf("ok", "bad"), SourceRanker.rank(listOf(bad, source("ok", quality = "480p")), store).map { it.id })
    }

    @Test fun deviceMatching() {
        val preferences = SourcePreferences(device = SourcePreferences.DeviceSupport(hdr = false, dolbyVision = false, av1 = false))
        val ranked = SourceRanker.rank(listOf(source("dv", tags = listOf("DV", "HDR")), source("av1", tags = listOf("AV1")), source("plain")),
            memory(), preferences = preferences).map { it.id }
        assertEquals("plain", ranked.first())
        assertEquals("av1", ranked.last())
    }

    @Test fun preferredGroupAndLanguage() {
        val ranked = SourceRanker.rank(listOf(source("x", release = "Film.1080p-OTHER"), source("y", release = "Film.1080p-FLUX")),
            memory(), preferences = SourcePreferences.none.copy(groups = listOf("FLUX"))).map { it.id }
        assertEquals(listOf("y", "x"), ranked)
        val byLanguage = SourceRanker.rank(listOf(source("en", release = "Film.1080p.ENG-X"), source("it", release = "Film.1080p.ITA.ENG-X")),
            memory(), preferences = SourcePreferences.none.copy(audioLanguage = "ita")).map { it.id }
        assertEquals(listOf("it", "en"), byLanguage)
    }

    @Test fun memoryRoundTrip() {
        val file = File(folder, "sources.json")
        val store = SourceMemory(file)
        store.noteSuccess(source("a"))
        store.saveNow()
        store.waitForSave()
        assertEquals(1, SourceMemory(file).record(source("a"))?.successes)
    }
}
