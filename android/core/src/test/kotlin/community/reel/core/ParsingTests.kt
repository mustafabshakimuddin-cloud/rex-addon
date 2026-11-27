package community.reel.core

import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.time.Instant
import kotlin.math.abs

/** Release parsing: what a Stremio stream's free text says, pulled apart. */
class ParsingTests {
    @Before fun setUp() { freshPlatform() }

    private fun stream(name: String, title: String, url: String? = "https://torrentio.strem.fun/resolve/realdebrid/KEY/abc/null/0/file.mkv",
                       hash: String? = "ABCDEF", index: Int? = 0): StreamSource =
        StremioStreams.source(StremioStreams.RawStream(name = name, title = title, url = url, infoHash = hash, fileIdx = index),
            0, "Torrentio", "torrentio.strem.fun")!!

    @Test fun torrentioLine() {
        val source = stream("[RD+] Torrentio\n4k DV | HDR",
            "Movie.2024.2160p.WEB-DL.DV.HDR.Atmos-FLUX\nMovie.2024.2160p.WEB-DL.DV.HDR.Atmos-FLUX.mkv\n👤 42 💾 18.3 GB ⚙️ TorrentGalaxy\n🇬🇧 / 🇫🇷")
        assertEquals("4K", source.quality)
        assertTrue(source.isCached)
        assertTrue("DV" in source.tags)
        assertTrue("HDR" in source.tags)
        assertTrue("Atmos" in source.tags)
        assertEquals(42, source.seeders)
        assertEquals("18.3 GB", source.size)
        assertTrue(abs(source.sizeBytes - 18.3 * 1_073_741_824) < 1)
        assertEquals("TorrentGalaxy", source.provider)
        assertEquals("FLUX", source.releaseGroup)
        assertEquals("abcdef", source.infoHash)
        assertTrue(source.needsResolve)
    }

    @Test fun tsExtensionIsNotACam() {
        assertEquals("Other", stream("[RD+] Comet", "Some.Show.S01E01.WEB.h264-GRP.ts").quality)
        assertEquals("CAM", stream("[RD+] Comet", "Movie.2025.HDTS.x264-GRP").quality)
    }

    @Test fun threeDAndCodecs() {
        val source = stream("[RD+] Torrentio\n1080p", "Avatar.2009.1080p.3D.HSBS.BluRay.x265-GRP")
        assertTrue("3D" in source.tags)
        assertTrue("HEVC" in source.tags)
        val plus = stream("[RD+] Torrentio\n4k", "Movie.2160p.HDR10+.AV1-GRP")
        assertTrue("HDR10+" in plus.tags)
        assertTrue("AV1" in plus.tags)
    }

    @Test fun pathSegment() {
        val config = TorrentioConfig(service = DebridService.REALDEBRID, key = " KEY|= ", providers = listOf("yts"), excludedQualities = listOf("cam"),
            sort = TorrentioSort.SEEDERS, maxSizeGB = 10, cachedOnly = true, priorityLanguages = listOf("french", "german"), perQualityLimit = 5)
        val segment = config.pathSegment
        for (part in listOf("providers=yts", "sort=seeders", "qualityfilter=cam", "sizefilter=10GB", "language=french,german", "limit=5", "debridoptions=nodownloadlinks")) {
            assertTrue(part, segment.contains(part))
        }
        assertTrue(segment.endsWith("realdebrid=KEY"))
        // As on iOS: "|" is encoded in the URL, "=" and "," are not.
        assertEquals("providers=yts%7Csort=seeders", Torrentio.encodeSegment("providers=yts|sort=seeders"))
    }

    @Test fun serverAddress() {
        assertEquals("https://my.torrentio.example", TorrentioConfig(server = "https://my.torrentio.example/manifest.json").serverBase)
        assertEquals(Torrentio.BASE, TorrentioConfig(server = "not a server").serverBase)
    }

    @Test fun filters() {
        val threeD = stream("[RD+] Comet", "Film.2010.1080p.3D.SBS-X")
        assertFalse(SourceFinder.passes(threeD, TorrentioConfig(service = DebridService.REALDEBRID, key = "k", excludedQualities = listOf("threed"))))
        val few = stream("[RD download] Torrentio\n1080p", "Film.1080p-X\n👤 3 💾 2 GB")
        assertFalse(few.isCached)
        assertFalse(SourceFinder.passes(few, TorrentioConfig(service = DebridService.REALDEBRID, key = "k", cachedOnly = false, minSeeders = 10)))
    }

    @Test fun mergeKeepsCachedCopy() {
        val uncached = stream("[RD download] Torrentio\n1080p", "Film.1080p-X")
        val cached = stream("[RD+] Comet", "Film.1080p-X").copy(addon = "Comet")
        val merged = SourceFinder.merge(listOf(listOf(uncached), listOf(cached)))
        assertEquals(1, merged.size)
        assertEquals("Comet", merged.first().addon)
    }

    @Test fun errorVideos() {
        assertEquals(ResolveError.AccessDenied, ResolveError.fromErrorVideo("https://torrentio.strem.fun/videos/failed_access_v2.mp4"))
        assertEquals(ResolveError.Downloading, ResolveError.fromErrorVideo("https://my.host/videos/downloading_v2.mp4"))
        assertNull(ResolveError.fromErrorVideo("https://download.real-debrid.com/d/ABC/videos/Film.mkv"))
    }

    @Test fun redaction() {
        val clean = Redact.text("https://torrentio.strem.fun/realdebrid=SECRETKEY|sort=size/resolve/realdebrid/SECRETKEY/abc?apikey=SECRET2")
        assertFalse(clean.contains("SECRETKEY"))
        assertFalse(clean.contains("SECRET2"))
        assertEquals("Authorization: Bearer •••", Redact.text("Authorization: Bearer abc.def"))
    }

    @Test fun languages() {
        assertEquals(listOf("fr", "fre", "fra"), Languages.codes("fre"))
        assertTrue(Languages.matches("de", "ger"))
        assertTrue("nl" in Languages.codes("dut"))
        assertFalse("may" in Languages.searchTerms("may"))
        assertTrue("italian" in Languages.searchTerms("ita"))
    }

    @Test fun realDebridAccount() {
        val json = buildJsonObject { put("username", "someone"); put("type", "premium"); put("expiration", "2030-01-02T03:04:05.000Z") }
        val info = DebridAccount.parse(DebridService.REALDEBRID, json)
        assertEquals("someone", info.username)
        assertEquals(true, info.premium)
        assertNotNull(info.expires)
        assertTrue(DebridAccount.supports(DebridService.REALDEBRID))
        assertFalse(DebridAccount.supports(DebridService.OFFCLOUD))
    }

    /** An addon's season or episode number may arrive as text, a float, or a value no Int can hold. */
    @Test fun flexibleNumbers() {
        assertEquals(3, JsonPrimitive(3).int())
        assertEquals(4, JsonPrimitive("4").int())
        assertEquals(5, JsonPrimitive(5.0).int())
        assertNull(JsonPrimitive(1e300).int())
        assertNull(null.int())
    }

    @Test fun traktStampsWithAndWithoutMilliseconds() {
        assertEquals(DateParsing.parse("2015-01-25T22:01:32.000Z"), DateParsing.parse("2015-01-25T22:01:32Z"))
        assertNull(DateParsing.parse("yesterday"))
    }

    @Test fun calendarFile() {
        val show = MediaItem(id = "tt0903747", kind = MediaKind.SERIES, name = "Breaking, Bad")
        val aired = Instant.ofEpochSecond(1_800_000_000)
        val episode = Episode("tt0903747:1:1", 1, 1, "Pilot; Part 1", released = aired)
        val text = CalendarExport.ics(listOf(CalendarEpisode(show, episode, aired)))
        assertTrue(text.startsWith("BEGIN:VCALENDAR\r\n"))
        assertTrue(text.contains("SUMMARY:Breaking\\, Bad S01E01"))
        assertTrue(text.contains("DESCRIPTION:Pilot\\; Part 1"))
        assertTrue(text.contains("DTSTART;VALUE=DATE:20270115"))
        assertTrue(text.endsWith("END:VCALENDAR\r\n"))
    }

    @Test fun flagsCountAsLanguage() {
        val source = StremioStreams.source(StremioStreams.RawStream(name = "[RD+] Torrentio\n1080p",
            title = "Film.2020.1080p-GRP\n👤 5 💾 2 GB ⚙️ YTS\n🇩🇪 / 🇬🇧", url = "https://example.com/x"), 0, "Torrentio", null)!!
        assertEquals("🇩🇪 / 🇬🇧", source.languages)
        assertEquals("YTS", source.provider)
        assertTrue(SourcePreferences.mentions("ger", source))
        assertFalse(SourcePreferences.mentions("fre", source))
    }

    @Test fun mockAnswersEverythingTheTourAsks() {
        val catalog = MockServer.answer("https://cinemeta-catalogs.strem.io/top/catalog/movie/top.json")
        assertEquals(200, catalog.first)
        assertEquals(12, parseJson(String(catalog.third))["metas"].objects().size)
        assertTrue(String(MockServer.answer("https://torrentio.strem.fun/stream/movie/tt9900001.json").third).contains("2160p"))
        assertTrue(String(MockServer.answer("https://v3-cinemeta.strem.io/meta/series/tt0903747.json").third).contains("videos"))
    }

    @Test fun cinemetaMeta() {
        val meta = parseJson(String(MockServer.answer("https://v3-cinemeta.strem.io/meta/series/tt0903747.json").third))["meta"].obj()!!
        val detail = Cinemeta.detail(meta, MediaKind.SERIES)!!
        assertEquals(16, detail.episodes.size)
        assertEquals(listOf(1, 2), detail.seasons)
        assertEquals("9.5", detail.item.rating)
        assertEquals("https://images.metahub.space/background/large/tt0903747/img", detail.item.background)
    }

    @Test fun byteSizes() {
        assertEquals("4.1 GB", formatBytes(4_100_000_000))
        assertEquals("950 KB", formatBytes(950_000))
        assertEquals("12 bytes", formatBytes(12))
    }

    @Test fun links() {
        assertEquals("tt0111161" to MediaKind.MOVIE, AppStores.title("reel://title/tt0111161?type=movie"))
        assertEquals("tt0903747" to MediaKind.SERIES, AppStores.title("https://www.imdb.com/title/tt0903747/?type=series"))
        assertNull(AppStores.title("https://example.com"))
    }
}
