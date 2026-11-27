package community.reel.core

import java.time.Year
import kotlin.properties.ReadWriteProperty
import kotlin.reflect.KProperty

enum class SubtitleStyle(val raw: String, val title: String) {
    OUTLINE("outline", "Outline"), SHADOW("shadow", "Drop shadow"), BOX("box", "Dark box");
    companion object { fun of(raw: String?) = entries.firstOrNull { it.raw == raw } }
}

enum class SubtitleColor(val raw: String, val argb: Long) {
    WHITE("white", 0xFFFFFFFF), YELLOW("yellow", 0xFFFFE14D), CYAN("cyan", 0xFF5CE1E6), GREEN("green", 0xFF7CF29A), PINK("pink", 0xFFFF8FD1);
    val title: String get() = raw.replaceFirstChar { it.uppercase() }
    companion object { fun of(raw: String?) = entries.firstOrNull { it.raw == raw } }
}

enum class PosterSize(val raw: String, val scale: Float) {
    SMALL("small", 0.84f), MEDIUM("medium", 1f), LARGE("large", 1.2f);
    val title: String get() = raw.replaceFirstChar { it.uppercase() }
    companion object { fun of(raw: String?) = entries.firstOrNull { it.raw == raw } }
}

/** The app's accent colour, and the deeper shade its gradients run to. The same choices as on iOS. */
enum class AccentChoice(val raw: String, val title: String, val argb: Long, val deep: Long) {
    ROSE("rose", "Rose", 0xFFF46BA8, 0xFF7542DB),
    VIOLET("violet", "Violet", 0xFFA885FF, 0xFF5233C7),
    OCEAN("ocean", "Ocean", 0xFF4CA8FF, 0xFF2942CC),
    MINT("mint", "Mint", 0xFF4CDBB2, 0xFF14738C),
    AMBER("amber", "Amber", 0xFFFFB247, 0xFFD94C33),
    CRIMSON("crimson", "Crimson", 0xFFFF5C61, 0xFF8C1A66);
    companion object { fun of(raw: String?) = entries.firstOrNull { it.raw == raw } }
}

/** The parts Home is built from. Each can be hidden or moved under Settings → Home Screen. */
enum class HomeSection(val raw: String, val title: String) {
    HERO("hero", "Featured"),
    WAITING("waiting", "Waiting on You"),
    CONTINUE_WATCHING("continueWatching", "Continue Watching"),
    NEW_EPISODES("newEpisodes", "New Episodes"),
    MY_LIST("myList", "My List"),
    POPULAR_MOVIES("popularMovies", "Popular Movies"),
    POPULAR_SERIES("popularSeries", "Popular Series"),
    NEW_MOVIES("newMovies", "New Movies"),
    TOP_MOVIES("topMovies", "Top Rated Movies"),
    TOP_SERIES("topSeries", "Top Rated Series"),
    NEW_SERIES("newSeries", "New Series"),
    SCI_FI("sciFi", "Sci-Fi"),
    ANIMATION("animation", "Animation"),
    CRIME_SERIES("crimeSeries", "Crime Series"),
    COMEDY("comedy", "Comedy"),
    TRENDING_MOVIES("trendingMovies", "Trending Movies"),
    TRENDING_SERIES("trendingSeries", "Trending Series"),
    RECOMMENDED_MOVIES("recommendedMovies", "Movies for You"),
    RECOMMENDED_SERIES("recommendedSeries", "Series for You");

    /** What a Trakt row lists; these show once Trakt is connected. */
    val traktList: Pair<Trakt.Discovery, MediaKind>?
        get() = when (this) {
            TRENDING_MOVIES -> Trakt.Discovery.TRENDING to MediaKind.MOVIE
            TRENDING_SERIES -> Trakt.Discovery.TRENDING to MediaKind.SERIES
            RECOMMENDED_MOVIES -> Trakt.Discovery.RECOMMENDED to MediaKind.MOVIE
            RECOMMENDED_SERIES -> Trakt.Discovery.RECOMMENDED to MediaKind.SERIES
            else -> null
        }

    data class CatalogueRow(val kind: MediaKind, val catalog: Cinemeta.Catalog, val genre: String?)

    /** What a catalogue row lists; null for the sections built from your own library. */
    val catalogue: CatalogueRow?
        get() {
            val year = Year.now().value.toString()
            return when (this) {
                POPULAR_MOVIES -> CatalogueRow(MediaKind.MOVIE, Cinemeta.Catalog.POPULAR, null)
                POPULAR_SERIES -> CatalogueRow(MediaKind.SERIES, Cinemeta.Catalog.POPULAR, null)
                NEW_MOVIES -> CatalogueRow(MediaKind.MOVIE, Cinemeta.Catalog.NEWEST, year)
                NEW_SERIES -> CatalogueRow(MediaKind.SERIES, Cinemeta.Catalog.NEWEST, year)
                TOP_MOVIES -> CatalogueRow(MediaKind.MOVIE, Cinemeta.Catalog.TOP_RATED, null)
                TOP_SERIES -> CatalogueRow(MediaKind.SERIES, Cinemeta.Catalog.TOP_RATED, null)
                SCI_FI -> CatalogueRow(MediaKind.MOVIE, Cinemeta.Catalog.POPULAR, "Sci-Fi")
                ANIMATION -> CatalogueRow(MediaKind.MOVIE, Cinemeta.Catalog.POPULAR, "Animation")
                CRIME_SERIES -> CatalogueRow(MediaKind.SERIES, Cinemeta.Catalog.POPULAR, "Crime")
                COMEDY -> CatalogueRow(MediaKind.MOVIE, Cinemeta.Catalog.POPULAR, "Comedy")
                else -> null
            }
        }

    companion object { fun of(raw: String?) = entries.firstOrNull { it.raw == raw } }
}

/** The settings, stored under the same keys as on iOS so backups move between platforms. */
class AppSettings : Observed() {
    private val defaults = Platform.defaults

    // Property delegates: read once at launch, written back and published on every change.
    private fun bool(key: String, default: Boolean) = Setting(defaults.bool(key) ?: default) { defaults.putBool(key, it) }
    private fun int(key: String, default: Int) = Setting(defaults.int(key) ?: default) { defaults.putInt(key, it) }
    private fun double(key: String, default: Double) = Setting(defaults.double(key) ?: default) { defaults.putDouble(key, it) }
    private fun string(key: String, default: String) = Setting(defaults.string(key) ?: default) { defaults.putString(key, it) }
    private fun strings(key: String, default: List<String>) = Setting(defaults.strings(key) ?: default) { defaults.putStrings(key, it) }
    private fun <E> choice(key: String, default: E, raw: (E) -> String, of: (String?) -> E?) =
        Setting(of(defaults.string(key)) ?: default) { defaults.putString(key, raw(it)) }

    private inner class Setting<T>(private var value: T, private val write: (T) -> Unit) : ReadWriteProperty<Any?, T> {
        override fun getValue(thisRef: Any?, property: KProperty<*>) = value
        override fun setValue(thisRef: Any?, property: KProperty<*>, value: T) {
            if (this.value == value) return
            this.value = value
            write(value)
            changed()
        }
    }

    var debridService by choice("debrid.service", DebridService.NONE, { it.raw }, DebridService::of)
    var debridKey: String = Platform.secrets.read("debrid.key") ?: ""
        set(value) { field = value; Platform.secrets.write(value.trim(), "debrid.key"); changed() }
    /** A second debrid service whose cached releases fill in what the first hasn't got. */
    var secondaryService by choice("debrid.secondaryService", DebridService.NONE, { it.raw }, DebridService::of)
    var secondaryKey: String = Platform.secrets.read("debrid.secondaryKey") ?: ""
        set(value) { field = value; Platform.secrets.write(value.trim(), "debrid.secondaryKey"); changed() }
    var providers by strings("torrentio.providers", emptyList())
    var excludedQualities by strings("torrentio.excludedQualities", listOf("scr", "cam"))
    var sort by choice("torrentio.sort", TorrentioSort.QUALITY, { it.raw }, TorrentioSort::of)
    var maxSizeGB by int("torrentio.maxSizeGB", 0)
    var cachedOnly by bool("torrentio.cachedOnly", true)
    var preferredSubtitleLanguage by string("player.subtitleLanguage", Languages.deviceDefault)
    /** ISO 639-2 code; empty keeps each file's default track. */
    var preferredAudioLanguage by string("player.audioLanguage", "")
    var autoplaySubtitles by bool("player.autoplaySubtitles", false)
    var autoPlayBest by bool("playback.autoPlayBest", false)
    /** Stremio addons whose streams are merged with Torrentio's. */
    var addons: List<StreamAddon> = defaults.string("sources.addons")?.let { text ->
        runCatching { parseJson(text).lossyList<StreamAddon>() }.getOrNull()
    } ?: emptyList()
        set(value) { field = value; defaults.putString("sources.addons", ReelJson.encodeToString(value)); changed() }
    /** Resolve the likely pick on a title page and fetch its first bytes. Off unless chosen. */
    var prepareAhead by bool("playback.prepareAhead", false)
    var subtitleScale by double("subtitles.scale", 1.0)
    var subtitleStyle by choice("subtitles.style", SubtitleStyle.OUTLINE, { it.raw }, SubtitleStyle::of)
    var subtitleColor by choice("subtitles.color", SubtitleColor.WHITE, { it.raw }, SubtitleColor::of)
    /** How far above the bottom of the picture subtitles sit, in points beyond the default. */
    var subtitleLift by double("subtitles.lift", 0.0)
    var subtitleBoxOpacity by double("subtitles.boxOpacity", 0.72)
    /** Grow subtitles with the system font size. */
    var subtitleFollowsTextSize by bool("subtitles.dynamicType", false)
    var searchOnlineSubtitles by bool("subtitles.online", true)
    var showSkipButtons by bool("player.skipButtons", true)
    var autoPlayNext by bool("player.autoPlayNext", true)
    var autoSkipIntro by bool("player.autoSkipIntro", false)
    var autoSkipRecap by bool("player.autoSkipRecap", false)
    /** Night mode: loud scenes come down and quiet ones up. */
    var nightMode by bool("player.nightMode", false)
    /** Extra level on the dialogue, in dB (0 is off). */
    var dialogueBoostDB by double("player.dialogueBoost", 0.0)
    var liftQuietSources by bool("player.liftQuiet", false)
    var torrentioServer by string("torrentio.server", Torrentio.BASE)
    var priorityLanguages by strings("torrentio.languages", emptyList())
    var perQualityLimit by int("torrentio.limit", 0)
    var minSeeders by int("torrentio.minSeeders", 0)
    var preferHDR by choice("prefer.hdr", Leaning.NEUTRAL, { it.raw }, Leaning::of)
    var preferDolbyVision by choice("prefer.dolbyVision", Leaning.NEUTRAL, { it.raw }, Leaning::of)
    var preferAtmos by choice("prefer.atmos", Leaning.NEUTRAL, { it.raw }, Leaning::of)
    var preferRemux by choice("prefer.remux", Leaning.NEUTRAL, { it.raw }, Leaning::of)
    var preferredGroups by strings("prefer.groups", emptyList())
    var preferAudioLanguageReleases by bool("prefer.audioLanguageReleases", true)
    var matchDevice by bool("prefer.matchDevice", true)
    var debridAccount: DebridAccountInfo? = defaults.string("debrid.account")?.let { runCatching { ReelJson.decodeFromString<DebridAccountInfo>(it) }.getOrNull() }
        set(value) { field = value; defaults.putString("debrid.account", value?.let { ReelJson.encodeToString(it) }); changed() }
    var downloadsOverCellular by bool("downloads.cellular", false)
    /** The largest release a download picks, in GB; 0 follows the streaming limit. */
    var downloadMaxSizeGB by int("downloads.maxSizeGB", 0)
    /** Delete finished downloads this many days after they were watched; 0 keeps them. */
    var deleteWatchedDownloadsAfterDays by int("downloads.deleteWatchedAfterDays", 0)
    var downloadSubtitles by bool("downloads.subtitles", true)
    var notifyNewEpisodes by bool("notify.episodes", false)
    var notifyDownloads by bool("notify.downloads", true)
    /** Leave watched films out of Explore and catalogue rows. */
    var hideWatched by bool("browse.hideWatched", false)
    var accent by choice("appearance.accent", AccentChoice.ROSE, { it.raw }, AccentChoice::of)
    var posterSize by choice("appearance.posterSize", PosterSize.MEDIUM, { it.raw }, PosterSize::of)
    var showRatings by bool("appearance.showRatings", true)
    var heroAutoAdvance by bool("appearance.heroAutoAdvance", true)

    /** Every Home section in the order chosen, shown or not. Sections added later join the end. */
    var homeOrder: List<HomeSection> = run {
        val saved = (defaults.strings("home.order") ?: emptyList()).mapNotNull(HomeSection::of)
        saved + HomeSection.entries.filter { it !in saved }
    }
        set(value) { field = value; defaults.putStrings("home.order", value.map { it.raw }); changed() }
    var homeHidden: Set<HomeSection> = (defaults.strings("home.hidden") ?: emptyList()).mapNotNull(HomeSection::of).toSet()
        set(value) { field = value; defaults.putStrings("home.hidden", value.map { it.raw }); changed() }

    /** Set once first-run setup has been finished or skipped; Settings can open it again. */
    var setupFinished by bool("setup.finished",
        // Someone who already set the app up before setup existed shouldn't be walked through it.
        (DebridService.of(defaults.string("debrid.service"))?.let { it != DebridService.NONE } ?: false) || addons.isNotEmpty())
    var recentSearches by strings("search.recent", emptyList()); private set

    /** Home's sections in order, without the hidden ones. */
    val visibleHomeSections: List<HomeSection> get() = homeOrder.filter { it !in homeHidden }

    fun resetHomeLayout() {
        homeOrder = HomeSection.entries.toList()
        homeHidden = emptySet()
    }

    fun rememberSearch(text: String) {
        val trimmed = text.trim()
        if (trimmed.length < 2) return
        recentSearches = listOf(trimmed) + recentSearches.filter { !it.equals(trimmed, ignoreCase = true) }.take(9)
    }

    fun forgetSearch(text: String) { recentSearches = recentSearches.filter { it != text } }
    fun clearRecentSearches() { recentSearches = emptyList() }

    val torrentio: TorrentioConfig
        get() = TorrentioConfig(
            service = debridService, key = debridKey, providers = providers, excludedQualities = excludedQualities,
            sort = sort, maxSizeGB = maxSizeGB, cachedOnly = cachedOnly, server = torrentioServer,
            priorityLanguages = priorityLanguages, perQualityLimit = perQualityLimit, minSeeders = minSeeders,
        )

    /** What decides between releases of the same quality. */
    val sourcePreferences: SourcePreferences
        get() = SourcePreferences(preferHDR, preferDolbyVision, preferAtmos, preferRemux, preferredGroups,
            if (preferAudioLanguageReleases) preferredAudioLanguage else "", matchDevice, Platform.device)

    /** The rules for a download: the same as streaming, with its own size ceiling when one is set. */
    val downloadQuery: SourceQuery
        get() {
            var config = torrentio
            if (downloadMaxSizeGB > 0) config = config.copy(maxSizeGB = if (config.maxSizeGB > 0) minOf(config.maxSizeGB, downloadMaxSizeGB) else downloadMaxSizeGB)
            val secondary = secondaryTorrentio?.copy(maxSizeGB = config.maxSizeGB)
            return SourceQuery(config, addons, secondary)
        }

    val isDebridConfigured: Boolean get() = torrentio.hasDebrid

    /** Torrentio needs a debrid service to give playable links; an addon may not. */
    val canFindSources: Boolean get() = isDebridConfigured || addons.any { it.enabled && it.hasStreams }

    val sourceQuery: SourceQuery get() = SourceQuery(torrentio, addons, secondaryTorrentio)

    /** The first service's rules with the second service's key, when one is set and differs. */
    val secondaryTorrentio: TorrentioConfig?
        get() {
            if (secondaryService == DebridService.NONE || secondaryService == debridService) return null
            val config = torrentio.copy(service = secondaryService, key = secondaryKey)
            return if (config.hasDebrid) config else null
        }

    /** Every settings key that belongs in a backup. */
    companion object {
        val backupPrefixes = listOf(
            "debrid.service", "debrid.secondaryService", "torrentio.", "player.", "playback.", "sources.", "subtitles.", "appearance.", "home.",
            "prefer.", "downloads.", "notify.", "browse.", "explore.", "library.", "search.", "setup.",
        )
    }
}
