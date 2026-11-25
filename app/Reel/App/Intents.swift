import AppIntents

/// "Resume watching in Reel": plays the newest entry of Continue Watching, picking its source
/// the way Play does when it chooses by itself.
struct ResumeWatchingIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume Watching"
    static var description = IntentDescription("Plays what you were watching last, from where you stopped.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let stores = AppStores.current, let entry = stores.library.continueWatching.first else { return .result() }
        stores.playback.play(entry.target, settings: stores.settings, library: stores.library, automatic: true)
        return .result()
    }
}

/// "Search Reel": opens Search with the words given.
struct SearchReelIntent: AppIntent {
    static var title: LocalizedStringResource = "Search Films and Series"
    static var description = IntentDescription("Opens Search with these words.")
    static var openAppWhenRun = true

    @Parameter(title: "Search for")
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult {
        AppStores.current?.router.search(query)
        return .result()
    }
}

struct ReelShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ResumeWatchingIntent(),
                    phrases: ["Resume watching in \(.applicationName)", "Continue watching in \(.applicationName)"],
                    shortTitle: "Resume Watching", systemImageName: "play.fill")
        AppShortcut(intent: SearchReelIntent(), phrases: ["Search \(.applicationName)"],
                    shortTitle: "Search", systemImageName: "magnifyingglass")
    }
}
