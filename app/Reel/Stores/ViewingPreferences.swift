import Foundation

/// The choices made in the player for one film or series: audio and subtitle language, subtitle
/// timing, fill and speed. The next episode starts the way the last one was left.
struct ViewingChoice: Codable, Equatable {
    /// ISO language of the audio track picked; nil follows the settings.
    var audioLanguage: String?
    /// ISO language of the subtitle track picked, "" for subtitles off; nil follows the settings.
    var subtitleLanguage: String?
    var subtitleDelay: Double = 0
    var fillsScreen = false
    var rate: Float = 1
    var updatedAt = Date()
    /// Where you skipped from and to near the start of an episode, so the next ones can offer
    /// the same skip when their files don't name an intro chapter.
    var introStart: Double?
    var introEnd: Double?
}

/// Kept in UserDefaults: small, and a lost entry only means the settings' defaults apply.
enum ViewingPreferences {
    /// One set per profile.
    private static var key: String { "player.choices" + ProfileStore.currentKeySuffix }
    private static let keep = 300

    static func choice(for titleID: String) -> ViewingChoice? {
        all()[titleID]
    }

    static func store(_ choice: ViewingChoice, for titleID: String) {
        var all = all()
        all[titleID] = choice
        if all.count > keep {
            for (id, _) in all.sorted(by: { $0.value.updatedAt < $1.value.updatedAt }).prefix(all.count - keep) { all[id] = nil }
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(all), forKey: key)
    }

    static func forgetAll() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func all() -> [String: ViewingChoice] {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([String: ViewingChoice].self, from: $0) } ?? [:]
    }
}
