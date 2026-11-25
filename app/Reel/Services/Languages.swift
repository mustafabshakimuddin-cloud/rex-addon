import Foundation

/// Language preferences, stored as ISO 639-2/B codes ("eng", "fre"). Files tag tracks with either
/// ISO 639-1 or either form of 639-2, and services use their own, so every form is matched.
enum Languages {
    private struct Entry {
        let code: String       // ISO 639-2/B
        let short: String      // ISO 639-1
        let terminology: String?  // ISO 639-2/T, where it differs
        let flag: String?
        /// Words release names use for it beyond its English name ("vostfr" aside).
        var extra: [String] = []
    }

    private static let table: [Entry] = [
        Entry(code: "eng", short: "en", terminology: nil, flag: "🇬🇧"),
        Entry(code: "spa", short: "es", terminology: nil, flag: "🇪🇸", extra: ["castellano", "latino", "esp"]),
        Entry(code: "fre", short: "fr", terminology: "fra", flag: "🇫🇷", extra: ["vff", "truefrench"]),
        Entry(code: "ger", short: "de", terminology: "deu", flag: "🇩🇪", extra: ["deutsch"]),
        Entry(code: "ita", short: "it", terminology: nil, flag: "🇮🇹"),
        Entry(code: "por", short: "pt", terminology: nil, flag: "🇵🇹", extra: ["dublado"]),
        Entry(code: "dut", short: "nl", terminology: "nld", flag: "🇳🇱", extra: ["nederlands"]),
        Entry(code: "pol", short: "pl", terminology: nil, flag: "🇵🇱", extra: ["polski"]),
        Entry(code: "swe", short: "sv", terminology: nil, flag: "🇸🇪"),
        Entry(code: "nor", short: "no", terminology: nil, flag: "🇳🇴"),
        Entry(code: "dan", short: "da", terminology: nil, flag: "🇩🇰"),
        Entry(code: "fin", short: "fi", terminology: nil, flag: "🇫🇮"),
        Entry(code: "ice", short: "is", terminology: "isl", flag: "🇮🇸"),
        Entry(code: "rus", short: "ru", terminology: nil, flag: "🇷🇺"),
        Entry(code: "ukr", short: "uk", terminology: nil, flag: "🇺🇦"),
        Entry(code: "cze", short: "cs", terminology: "ces", flag: "🇨🇿"),
        Entry(code: "slo", short: "sk", terminology: "slk", flag: "🇸🇰"),
        Entry(code: "slv", short: "sl", terminology: nil, flag: "🇸🇮"),
        Entry(code: "hun", short: "hu", terminology: nil, flag: "🇭🇺"),
        Entry(code: "rum", short: "ro", terminology: "ron", flag: "🇷🇴"),
        Entry(code: "bul", short: "bg", terminology: nil, flag: "🇧🇬"),
        Entry(code: "hrv", short: "hr", terminology: nil, flag: "🇭🇷"),
        Entry(code: "srp", short: "sr", terminology: nil, flag: "🇷🇸"),
        Entry(code: "gre", short: "el", terminology: "ell", flag: "🇬🇷"),
        Entry(code: "tur", short: "tr", terminology: nil, flag: "🇹🇷"),
        Entry(code: "ara", short: "ar", terminology: nil, flag: "🇸🇦"),
        Entry(code: "heb", short: "he", terminology: nil, flag: "🇮🇱"),
        Entry(code: "per", short: "fa", terminology: "fas", flag: "🇮🇷", extra: ["farsi"]),
        Entry(code: "hin", short: "hi", terminology: nil, flag: "🇮🇳"),
        Entry(code: "urd", short: "ur", terminology: nil, flag: "🇵🇰"),
        Entry(code: "ben", short: "bn", terminology: nil, flag: "🇧🇩"),
        Entry(code: "tam", short: "ta", terminology: nil, flag: nil),
        Entry(code: "tel", short: "te", terminology: nil, flag: nil),
        Entry(code: "mal", short: "ml", terminology: nil, flag: nil),
        Entry(code: "tha", short: "th", terminology: nil, flag: "🇹🇭"),
        Entry(code: "vie", short: "vi", terminology: nil, flag: "🇻🇳"),
        Entry(code: "ind", short: "id", terminology: nil, flag: "🇮🇩"),
        Entry(code: "may", short: "ms", terminology: "msa", flag: "🇲🇾"),
        Entry(code: "fil", short: "tl", terminology: "tgl", flag: "🇵🇭", extra: ["tagalog"]),
        Entry(code: "chi", short: "zh", terminology: "zho", flag: "🇨🇳", extra: ["mandarin", "cantonese"]),
        Entry(code: "jpn", short: "ja", terminology: nil, flag: "🇯🇵"),
        Entry(code: "kor", short: "ko", terminology: nil, flag: "🇰🇷"),
    ]

    private static let english = Locale(identifier: "en")

    /// Every language offered in Settings, "Default" first, then by name in the reader's language.
    static let options: [(String, String)] = {
        let named = table.map { ($0.code, displayName($0)) }.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
        return [("", "Default")] + named
    }()

    private static func displayName(_ entry: Entry) -> String {
        Locale.current.localizedString(forLanguageCode: entry.short)?.capitalized(with: Locale.current)
            ?? english.localizedString(forLanguageCode: entry.short) ?? entry.code.uppercased()
    }

    private static func entry(for code: String) -> Entry? {
        let lower = code.lowercased()
        return table.first { $0.code == lower || $0.short == lower || $0.terminology == lower }
    }

    /// The forms a file or service may use for a stored code, ISO 639-1 first.
    static func codes(for code: String) -> [String] {
        guard !code.isEmpty else { return [] }
        guard let entry = entry(for: code) else { return [code.lowercased()] }
        return [entry.short, entry.code, entry.terminology].compactMap { $0 }
    }

    /// The device's own language as a stored code, or English when it isn't listed.
    static var deviceDefault: String {
        let short = Locale.current.language.languageCode?.identifier ?? "en"
        return entry(for: short)?.code ?? "eng"
    }

    /// A readable name for a language code in any of the forms files and services use.
    static func name(for code: String) -> String {
        if let entry = entry(for: code) { return displayName(entry) }
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.lowercased() != "und" else { return code.uppercased() }
        return Locale.current.localizedString(forLanguageCode: trimmed) ?? trimmed.uppercased()
    }

    /// Whether two codes name the same language ("en", "eng").
    static func matches(_ code: String, preferred: String) -> Bool {
        guard !preferred.isEmpty else { return false }
        return codes(for: preferred).contains(code.lowercased())
    }

    /// Words that mark a release as carrying this language: its English name, its three-letter
    /// code, its flag and common tags, all lower-cased.
    static func searchTerms(for code: String) -> [String] {
        guard let entry = entry(for: code) else { return [] }
        // Some codes are everyday words ("may", "ice", "per"); those match too much to use.
        let ambiguous: Set<String> = ["ice", "may", "per", "fil", "ind", "tam", "tel", "mal", "ben", "slo", "srp"]
        var terms = (ambiguous.contains(entry.code) ? [] : [entry.code]) + entry.extra
        if let name = english.localizedString(forLanguageCode: entry.short)?.lowercased() { terms.append(name) }
        if let flag = entry.flag { terms.append(flag) }
        return terms
    }
}
