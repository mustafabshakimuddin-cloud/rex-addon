package community.reel.core

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import java.time.Instant

object AppConfig {
    const val NAME = "Reel"
    /// Set by the app at launch: "0.1.42".
    @Volatile var version: String = "1.0"
}

@Serializable
enum class MediaKind(val raw: String) {
    @SerialName("movie") MOVIE("movie"),
    @SerialName("series") SERIES("series");

    val title: String get() = if (this == MOVIE) "Movies" else "Series"
    val singular: String get() = if (this == MOVIE) "Movie" else "Series"

    companion object {
        fun of(raw: String?): MediaKind? = entries.firstOrNull { it.raw == raw }
    }
}

/** Dates on disk and on the wire as ISO-8601 text. */
object InstantSerializer : KSerializer<Instant> {
    override val descriptor = PrimitiveSerialDescriptor("Instant", PrimitiveKind.STRING)
    override fun serialize(encoder: Encoder, value: Instant) = encoder.encodeString(value.toString())
    override fun deserialize(decoder: Decoder): Instant = Instant.parse(decoder.decodeString())
}

typealias Date = @Serializable(with = InstantSerializer::class) Instant

fun now(): Instant = Clock.now()

/** The clock the app reads; tests move it. */
object Clock {
    @Volatile var override: Instant? = null
    fun now(): Instant = override ?: Instant.now()
}

/** A title as shown in lists: what a Cinemeta catalogue entry provides. */
@Serializable
data class MediaItem(
    val id: String,          // IMDb id, e.g. tt0111161
    val kind: MediaKind,
    val name: String = id,
    val poster: String? = null,
    val background: String? = null,
    val logo: String? = null,
    val year: String? = null,
    val rating: String? = null,
    val genres: List<String> = emptyList(),
    val overview: String? = null,
)

@Serializable
data class Episode(
    val id: String,          // Stremio video id, e.g. tt0903747:1:2
    val season: Int,
    val number: Int,
    val title: String,
    val overview: String? = null,
    val thumbnail: String? = null,
    val released: Date? = null,
) {
    val code: String get() = String.format(java.util.Locale.ROOT, "S%02dE%02d", season, number)
    val hasAired: Boolean get() = released?.let { !it.isAfter(now()) } ?: true
}

/** Everything the detail page shows. */
data class MediaDetail(
    val item: MediaItem,
    val runtime: String? = null,
    val released: Instant? = null,
    val cast: List<String> = emptyList(),
    val directors: List<String> = emptyList(),
    val episodes: List<Episode> = emptyList(),
    val trailerYouTubeID: String? = null,
) {
    /** Regular seasons first, specials (season 0) last. */
    val seasons: List<Int>
        get() {
            val all = episodes.map { it.season }.toSet()
            return all.filter { it > 0 }.sorted() + if (0 in all) listOf(0) else emptyList()
        }

    fun episodes(season: Int): List<Episode> = episodes.filter { it.season == season }.sortedBy { it.number }
}

/** What the player is asked to play: a title, and an episode for series. */
@Serializable
data class PlaybackTarget(val item: MediaItem, val episode: Episode? = null) {
    /** Stremio video id: the IMDb id for films, `id:season:episode` for episodes. */
    val videoID: String get() = episode?.id ?: item.id
    val id: String get() = videoID
    val displayTitle: String get() = episode?.let { "${item.name} · ${it.code}" } ?: item.name
}

/** A title known only by its id, as links and notifications give it. */
fun MediaItem.Companion.placeholder(id: String, kind: MediaKind) = MediaItem(
    id = id, kind = kind, name = "",
    poster = "https://images.metahub.space/poster/medium/$id/img",
    background = "https://images.metahub.space/background/medium/$id/img",
    logo = "https://images.metahub.space/logo/medium/$id/img",
)
