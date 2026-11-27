package community.reel.core

import kotlinx.serialization.Serializable
import java.io.File

/** What happened the times a file, a release group or an addon was played. */
@Serializable
data class SourceRecord(
    val successes: Int = 0,
    val failures: Int = 0,
    val stalls: Int = 0,
    val lastFailure: String? = null,
    val updatedAt: Date = now(),
) {
    /** Positive when it has worked more than it has failed. */
    val balance: Int get() = successes - 2 * failures
}

/** What the player read from the file itself, before anyone pressed Play. */
@Serializable
data class SourceVerification(
    val videoFormat: String,          // "Dolby Vision", "HDR10+", "HDR10", "HLG", "SDR"
    val dolbyVisionProfile: Int? = null,
    val resolution: String? = null,   // "3840×2160"
    val bitDepth: Int? = null,
    val codec: String? = null,
    val atmos: Boolean = false,
    val audio: String? = null,        // "E-AC-3 · 5.1"
    val checkedAt: Date = now(),
) {
    val badges: List<String>
        get() {
            val badges = mutableListOf<String>()
            if (videoFormat != "SDR") badges += dolbyVisionProfile?.let { "$videoFormat P$it" } ?: videoFormat
            if (atmos) badges += "Atmos"
            if (bitDepth != null && bitDepth > 8) badges += "$bitDepth-bit"
            return badges
        }
}

/**
 * Learns which sources actually play, so the next pick avoids what failed and favours what worked.
 * Three levels, from most to least specific: the exact file, the release group that made it, and
 * the addon that listed it.
 */
class SourceMemory(file: File = JSONFile.file("sources.json")) : Observed() {
    var records: Map<String, SourceRecord> = emptyMap(); private set
    var verified: Map<String, SourceVerification> = emptyMap(); private set

    private val writer = SnapshotWriter(file)

    init {
        JSONFile.read(file) { json ->
            if (json["records"] == null && json["verified"] == null) error("Not a source memory file")
            Saved(json["records"].lossyMap(), json["verified"].lossyMap())
        }?.let {
            records = it.records
            verified = it.verified
        }
    }

    fun record(source: StreamSource) = records[fileKey(source)]
    fun groupRecord(source: StreamSource) = source.releaseGroup?.let { records["group:$it"] }
    fun verification(source: StreamSource) = verified[source.fileKey]

    /**
     * How strongly history argues for this source. The file's own history dominates; a release
     * group only nudges, because one bad encode says little about a group's next one.
     */
    fun score(source: StreamSource): Double {
        var score = 0.0
        record(source)?.let { file ->
            score += file.balance * 4.0
            if (file.failures > file.successes) score -= 100
        }
        groupRecord(source)?.let { score += it.balance.coerceIn(-5, 5).toDouble() }
        records["addon:${source.addon}"]?.let { score += it.balance.coerceIn(-2, 2) * 0.5 }
        return score
    }

    /** Whether the file failed the last time it was tried and never worked since. */
    fun failedBefore(source: StreamSource) = record(source)?.let { it.failures > it.successes } ?: false

    fun playedWell(source: StreamSource) = record(source)?.let { it.successes > 0 && it.failures == 0 } ?: false

    fun noteSuccess(source: StreamSource) = update(source) { it.copy(successes = it.successes + 1) }

    fun noteFailure(source: StreamSource, reason: String) =
        update(source) { it.copy(failures = it.failures + 1, lastFailure = reason) }

    fun noteStall(source: StreamSource) = update(source, fileOnly = true) { it.copy(stalls = it.stalls + 1) }

    fun store(verification: SourceVerification, source: StreamSource) {
        verified = verified + (source.fileKey to verification)
        changed()
        scheduleSave()
    }

    fun forgetAll() {
        records = emptyMap()
        verified = emptyMap()
        changed()
        scheduleSave()
    }

    private fun update(source: StreamSource, fileOnly: Boolean = false, change: (SourceRecord) -> SourceRecord) {
        val keys = mutableListOf(fileKey(source))
        if (!fileOnly) {
            source.releaseGroup?.let { keys += "group:$it" }
            keys += "addon:${source.addon}"
        }
        val next = records.toMutableMap()
        for (key in keys) next[key] = change(next[key] ?: SourceRecord()).copy(updatedAt = now())
        if (next.size > MAXIMUM_RECORDS) {
            next.entries.sortedBy { it.value.updatedAt }.take(next.size - MAXIMUM_RECORDS).forEach { next.remove(it.key) }
        }
        records = next
        changed()
        scheduleSave()
    }

    @Serializable
    data class Saved(val records: Map<String, SourceRecord>, val verified: Map<String, SourceVerification>)

    val snapshot: Saved get() = Saved(records, verified)

    /** Replaces everything learned with a backup's. */
    fun restore(saved: Saved) {
        records = saved.records
        verified = saved.verified
        changed()
        scheduleSave()
    }

    private fun scheduleSave() {
        val snapshot = snapshot
        writer.schedule(1.0) { ReelJson.encodeToString(Saved.serializer(), snapshot) }
    }

    fun saveNow() {
        val snapshot = snapshot
        writer.flush { ReelJson.encodeToString(Saved.serializer(), snapshot) }
    }

    fun waitForSave() = writer.waitUntilWritten()

    companion object {
        private const val MAXIMUM_RECORDS = 3000
        private fun fileKey(source: StreamSource) = "file:${source.fileKey}"
    }
}

/**
 * Orders sources for the automatic pick. Instant (cached) sources first, then the user's quality
 * order, and within a quality, history decides before the addon's own order does. A file that
 * failed and never worked since goes to the very end.
 */
object SourceRanker {
    private data class Key(
        val source: StreamSource, val offset: Int, val failed: Boolean, val cached: Boolean,
        val sameGroup: Boolean, val quality: Int, val preference: Double, val score: Double,
    )

    fun rank(
        sources: List<StreamSource>, memory: SourceMemory, preferGroup: String? = null,
        preferences: SourcePreferences = SourcePreferences.none,
    ): List<StreamSource> {
        val keys = sources.mapIndexedNotNull { offset, source ->
            if (!source.isPlayable) return@mapIndexedNotNull null
            Key(source, offset, memory.failedBefore(source), source.isCached,
                preferGroup != null && source.bingeGroup == preferGroup, source.qualityRank,
                preferences.score(source), memory.score(source))
        }
        return keys.sortedWith(
            compareBy<Key> { it.failed }
                .thenByDescending { it.cached }
                .thenByDescending { it.sameGroup }
                .thenBy { it.quality }
                .thenByDescending { it.preference }
                .thenByDescending { it.score }
                .thenBy { it.offset },
        ).map { it.source }
    }
}
