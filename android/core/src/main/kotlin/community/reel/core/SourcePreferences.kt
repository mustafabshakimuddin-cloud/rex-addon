package community.reel.core

/** How much a kind of release is wanted: favoured, no opinion, or kept to the last resort. */
enum class Leaning(val raw: String, val title: String, val weight: Double) {
    PREFER("prefer", "Prefer", 1.0),
    NEUTRAL("neutral", "No preference", 0.0),
    AVOID("avoid", "Avoid", -1.0);

    companion object {
        fun of(raw: String?) = entries.firstOrNull { it.raw == raw }
    }
}

/**
 * What the viewer likes in a release, beyond its resolution. Within one quality these decide
 * before history does; they never lift a 720p release above a 1080p one.
 */
data class SourcePreferences(
    val hdr: Leaning = Leaning.NEUTRAL,
    val dolbyVision: Leaning = Leaning.NEUTRAL,
    val atmos: Leaning = Leaning.NEUTRAL,
    val remux: Leaning = Leaning.NEUTRAL,
    /** Release groups to favour, upper-cased ("FLUX", "NTb"). */
    val groups: List<String> = emptyList(),
    /** ISO 639-2 audio language to favour in multi-language releases; empty for none. */
    val audioLanguage: String = "",
    /** Skip what this device can't show or decode in hardware. */
    val matchDevice: Boolean = true,
    val device: DeviceSupport = DeviceSupport.assumeAll,
) {
    /** What the screen and chip can do. */
    data class DeviceSupport(val hdr: Boolean, val dolbyVision: Boolean, val av1: Boolean) {
        companion object { val assumeAll = DeviceSupport(hdr = true, dolbyVision = true, av1 = true) }
    }

    fun score(source: StreamSource): Double {
        var score = 0.0
        val isDV = source.hasDolbyVision
        val isHDR = source.hasHDR
        if (isHDR) score += hdr.weight * 3
        if (isDV) score += dolbyVision.weight * 3
        if ("Atmos" in source.tags) score += atmos.weight * 2
        if ("Remux" in source.tags) score += remux.weight * 2
        val group = source.releaseGroup
        if (group != null && groups.any { it.equals(group, ignoreCase = true) }) score += 4
        if (audioLanguage.isNotEmpty() && mentions(audioLanguage, source)) score += 2
        if (matchDevice) {
            // A Dolby Vision-only file (profile 5) shows wrong colours where DV isn't supported;
            // HDR on an SDR screen is tone-mapped and loses the point of the bigger file.
            if (isDV && !device.dolbyVision) score -= 3
            if (isHDR && !device.hdr) score -= 2
            if ("AV1" in source.tags && !device.av1) score -= 6
        }
        return score
    }

    companion object {
        val none = SourcePreferences(matchDevice = false)

        /** Whether a release's name or language line names a language ("ITA", "German", 🇩🇪…). */
        fun mentions(code: String, source: StreamSource): Boolean {
            val words = Languages.searchTerms(code)
            if (words.isEmpty()) return false
            val haystack = listOf(source.release, source.file ?: "", source.languages ?: "").joinToString(" ").lowercase()
            return words.any { word ->
                val isFlag = word.codePoints().anyMatch { it in 0x1F1E6..0x1F1FF }
                if (isFlag || word.length > 3) haystack.contains(word)
                else Regex("\\b${Regex.escape(word)}\\b").containsMatchIn(haystack)
            }
        }
    }
}
