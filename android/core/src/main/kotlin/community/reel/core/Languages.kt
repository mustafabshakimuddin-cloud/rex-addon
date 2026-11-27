package community.reel.core

import java.util.Locale

/**
 * Language preferences, stored as ISO 639-2/B codes ("eng", "fre"). Files tag tracks with either
 * ISO 639-1 or either form of 639-2, and services use their own, so every form is matched.
 */
object Languages {
    private data class Entry(
        val code: String,          // ISO 639-2/B
        val short: String,         // ISO 639-1
        val terminology: String?,  // ISO 639-2/T, where it differs
        val flag: String?,
        /** Words release names use for it beyond its English name. */
        val extra: List<String> = emptyList(),
    )

    private val table = listOf(
        Entry("eng", "en", null, "🇬🇧"),
        Entry("spa", "es", null, "🇪🇸", listOf("castellano", "latino", "esp")),
        Entry("fre", "fr", "fra", "🇫🇷", listOf("vff", "truefrench")),
        Entry("ger", "de", "deu", "🇩🇪", listOf("deutsch")),
        Entry("ita", "it", null, "🇮🇹"),
        Entry("por", "pt", null, "🇵🇹", listOf("dublado")),
        Entry("dut", "nl", "nld", "🇳🇱", listOf("nederlands")),
        Entry("pol", "pl", null, "🇵🇱", listOf("polski")),
        Entry("swe", "sv", null, "🇸🇪"),
        Entry("nor", "no", null, "🇳🇴"),
        Entry("dan", "da", null, "🇩🇰"),
        Entry("fin", "fi", null, "🇫🇮"),
        Entry("ice", "is", "isl", "🇮🇸"),
        Entry("rus", "ru", null, "🇷🇺"),
        Entry("ukr", "uk", null, "🇺🇦"),
        Entry("cze", "cs", "ces", "🇨🇿"),
        Entry("slo", "sk", "slk", "🇸🇰"),
        Entry("slv", "sl", null, "🇸🇮"),
        Entry("hun", "hu", null, "🇭🇺"),
        Entry("rum", "ro", "ron", "🇷🇴"),
        Entry("bul", "bg", null, "🇧🇬"),
        Entry("hrv", "hr", null, "🇭🇷"),
        Entry("srp", "sr", null, "🇷🇸"),
        Entry("gre", "el", "ell", "🇬🇷"),
        Entry("tur", "tr", null, "🇹🇷"),
        Entry("ara", "ar", null, "🇸🇦"),
        Entry("heb", "he", null, "🇮🇱"),
        Entry("per", "fa", "fas", "🇮🇷", listOf("farsi")),
        Entry("hin", "hi", null, "🇮🇳"),
        Entry("urd", "ur", null, "🇵🇰"),
        Entry("ben", "bn", null, "🇧🇩"),
        Entry("tam", "ta", null, null),
        Entry("tel", "te", null, null),
        Entry("mal", "ml", null, null),
        Entry("tha", "th", null, "🇹🇭"),
        Entry("vie", "vi", null, "🇻🇳"),
        Entry("ind", "id", null, "🇮🇩"),
        Entry("may", "ms", "msa", "🇲🇾"),
        Entry("fil", "tl", "tgl", "🇵🇭", listOf("tagalog")),
        Entry("chi", "zh", "zho", "🇨🇳", listOf("mandarin", "cantonese")),
        Entry("jpn", "ja", null, "🇯🇵"),
        Entry("kor", "ko", null, "🇰🇷"),
    )

    private fun displayName(entry: Entry): String {
        val here = Locale.getDefault()
        val name = Locale.forLanguageTag(entry.short).getDisplayLanguage(here)
        return if (name.isNotEmpty() && name != entry.short) name.replaceFirstChar { it.titlecase(here) } else entry.code.uppercase()
    }

    /** Every language offered in Settings, "Default" first, then by name in the reader's language. */
    val options: List<Pair<String, String>>
        get() = listOf("" to "Default") + table.map { it.code to displayName(it) }.sortedBy { it.second.lowercase() }

    private fun entry(code: String): Entry? {
        val lower = code.lowercase()
        return table.firstOrNull { it.code == lower || it.short == lower || it.terminology == lower }
    }

    /** The forms a file or service may use for a stored code, ISO 639-1 first. */
    fun codes(code: String): List<String> {
        if (code.isEmpty()) return emptyList()
        val entry = entry(code) ?: return listOf(code.lowercase())
        return listOfNotNull(entry.short, entry.code, entry.terminology)
    }

    /** The device's own language as a stored code, or English when it isn't listed. */
    val deviceDefault: String get() = entry(Platform.languageCode)?.code ?: "eng"

    /** A readable name for a language code in any of the forms files and services use. */
    fun name(code: String): String {
        entry(code)?.let { return displayName(it) }
        val trimmed = code.trim()
        if (trimmed.isEmpty() || trimmed.lowercase() == "und") return code.uppercase()
        val name = Locale.forLanguageTag(trimmed).getDisplayLanguage(Locale.getDefault())
        return if (name.isNotEmpty() && name != trimmed) name else trimmed.uppercase()
    }

    /** Whether two codes name the same language ("en", "eng"). */
    fun matches(code: String, preferred: String): Boolean =
        preferred.isNotEmpty() && code.lowercase() in codes(preferred)

    /**
     * Words that mark a release as carrying this language: its English name, its three-letter
     * code, its flag and common tags, all lower-cased.
     */
    fun searchTerms(code: String): List<String> {
        val entry = entry(code) ?: return emptyList()
        // Some codes are everyday words ("may", "ice", "per"); those match too much to use.
        val ambiguous = setOf("ice", "may", "per", "fil", "ind", "tam", "tel", "mal", "ben", "slo", "srp")
        val terms = (if (entry.code in ambiguous) emptyList() else listOf(entry.code)).toMutableList()
        terms += entry.extra
        val english = Locale.forLanguageTag(entry.short).getDisplayLanguage(Locale.ENGLISH).lowercase()
        if (english.isNotEmpty() && english != entry.short) terms += english
        entry.flag?.let { terms += it }
        return terms
    }
}
