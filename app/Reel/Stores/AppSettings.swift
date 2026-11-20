import Foundation
import Combine

@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var debridService: DebridService { didSet { defaults.set(debridService.rawValue, forKey: Keys.service) } }
    @Published var debridKey: String { didSet { Keychain.write(debridKey.trimmingCharacters(in: .whitespacesAndNewlines), for: Keys.debridKey) } }
    @Published var providers: [String] { didSet { defaults.set(providers, forKey: Keys.providers) } }
    @Published var excludedQualities: [String] { didSet { defaults.set(excludedQualities, forKey: Keys.excluded) } }
    @Published var sort: TorrentioSort { didSet { defaults.set(sort.rawValue, forKey: Keys.sort) } }
    @Published var maxSizeGB: Int { didSet { defaults.set(maxSizeGB, forKey: Keys.maxSize) } }
    @Published var cachedOnly: Bool { didSet { defaults.set(cachedOnly, forKey: Keys.cachedOnly) } }
    @Published var preferredSubtitleLanguage: String { didSet { defaults.set(preferredSubtitleLanguage, forKey: Keys.subtitleLanguage) } }
    /// ISO 639-2 code; empty keeps each file's default track.
    @Published var preferredAudioLanguage: String { didSet { defaults.set(preferredAudioLanguage, forKey: Keys.audioLanguage) } }
    @Published var autoplaySubtitles: Bool { didSet { defaults.set(autoplaySubtitles, forKey: Keys.autoplaySubtitles) } }
    @Published var autoPlayBest: Bool { didSet { defaults.set(autoPlayBest, forKey: Keys.autoPlayBest) } }
    /// Stremio addons whose streams are merged with Torrentio's.
    @Published var addons: [StreamAddon] { didSet { defaults.set(try? JSONEncoder().encode(addons), forKey: Keys.addons) } }
    /// Resolve the likely pick on a title page and fetch its first bytes. Adds that release to the
    /// debrid account before Play is pressed, so it is off unless chosen.
    @Published var prepareAhead: Bool { didSet { defaults.set(prepareAhead, forKey: Keys.prepareAhead) } }
    @Published var subtitleScale: Double { didSet { defaults.set(subtitleScale, forKey: Keys.subtitleScale) } }
    @Published var subtitleStyle: SubtitleStyle { didSet { defaults.set(subtitleStyle.rawValue, forKey: Keys.subtitleStyle) } }
    @Published var subtitleColor: SubtitleColor { didSet { defaults.set(subtitleColor.rawValue, forKey: Keys.subtitleColor) } }
    /// Search OpenSubtitles when a file has no subtitles in the preferred language.
    @Published var searchOnlineSubtitles: Bool { didSet { defaults.set(searchOnlineSubtitles, forKey: Keys.onlineSubtitles) } }
    /// Show Skip Intro / Skip Credits when the file's chapters name them.
    @Published var showSkipButtons: Bool { didSet { defaults.set(showSkipButtons, forKey: Keys.skipButtons) } }
    /// Offer the next episode near the end of one, and start it after a countdown.
    @Published var autoPlayNext: Bool { didSet { defaults.set(autoPlayNext, forKey: Keys.autoPlayNext) } }

    // MARK: Appearance
    @Published var accent: AccentChoice {
        didSet { Theme.choice = accent; defaults.set(accent.rawValue, forKey: Keys.accent) }
    }
    @Published var posterSize: PosterSize { didSet { defaults.set(posterSize.rawValue, forKey: Keys.posterSize) } }
    @Published var showRatings: Bool { didSet { defaults.set(showRatings, forKey: Keys.showRatings) } }
    @Published var heroAutoAdvance: Bool { didSet { defaults.set(heroAutoAdvance, forKey: Keys.heroAutoAdvance) } }

    // MARK: Home screen
    /// Every Home section in the order chosen, shown or not.
    @Published var homeOrder: [HomeSection] { didSet { defaults.set(homeOrder.map(\.rawValue), forKey: Keys.homeOrder) } }
    @Published var homeHidden: Set<HomeSection> { didSet { defaults.set(homeHidden.map(\.rawValue), forKey: Keys.homeHidden) } }

    // MARK: Setup and search
    /// Set once the first-run setup has been finished or skipped; Settings can open it again.
    @Published var setupFinished: Bool { didSet { defaults.set(setupFinished, forKey: Keys.setupFinished) } }
    @Published private(set) var recentSearches: [String] { didSet { defaults.set(recentSearches, forKey: Keys.recentSearches) } }

    init() {
        debridService = DebridService(rawValue: defaults.string(forKey: Keys.service) ?? "") ?? .none
        debridKey = Keychain.read(Keys.debridKey) ?? ""
        providers = defaults.stringArray(forKey: Keys.providers) ?? []
        excludedQualities = defaults.stringArray(forKey: Keys.excluded) ?? ["scr", "cam"]
        sort = TorrentioSort(rawValue: defaults.string(forKey: Keys.sort) ?? "") ?? .quality
        maxSizeGB = defaults.object(forKey: Keys.maxSize) as? Int ?? 0
        cachedOnly = defaults.object(forKey: Keys.cachedOnly) as? Bool ?? true
        preferredSubtitleLanguage = defaults.string(forKey: Keys.subtitleLanguage) ?? "eng"
        preferredAudioLanguage = defaults.string(forKey: Keys.audioLanguage) ?? ""
        autoplaySubtitles = defaults.object(forKey: Keys.autoplaySubtitles) as? Bool ?? false
        autoPlayBest = defaults.object(forKey: Keys.autoPlayBest) as? Bool ?? false
        let savedAddons = (defaults.data(forKey: Keys.addons)).flatMap { try? JSONDecoder().decode([StreamAddon].self, from: $0) } ?? []
        addons = savedAddons
        prepareAhead = defaults.object(forKey: Keys.prepareAhead) as? Bool ?? false
        subtitleScale = defaults.object(forKey: Keys.subtitleScale) as? Double ?? 1
        subtitleStyle = SubtitleStyle(rawValue: defaults.string(forKey: Keys.subtitleStyle) ?? "") ?? .outline
        subtitleColor = SubtitleColor(rawValue: defaults.string(forKey: Keys.subtitleColor) ?? "") ?? .white
        searchOnlineSubtitles = defaults.object(forKey: Keys.onlineSubtitles) as? Bool ?? true
        showSkipButtons = defaults.object(forKey: Keys.skipButtons) as? Bool ?? true
        autoPlayNext = defaults.object(forKey: Keys.autoPlayNext) as? Bool ?? true
        let accent = AccentChoice(rawValue: defaults.string(forKey: Keys.accent) ?? "") ?? .rose
        self.accent = accent
        Theme.choice = accent
        posterSize = PosterSize(rawValue: defaults.string(forKey: Keys.posterSize) ?? "") ?? .medium
        showRatings = defaults.object(forKey: Keys.showRatings) as? Bool ?? true
        heroAutoAdvance = defaults.object(forKey: Keys.heroAutoAdvance) as? Bool ?? true
        // Sections added in later versions join the end of a saved order.
        let saved = (defaults.stringArray(forKey: Keys.homeOrder) ?? []).compactMap(HomeSection.init(rawValue:))
        homeOrder = saved + HomeSection.allCases.filter { !saved.contains($0) }
        homeHidden = Set((defaults.stringArray(forKey: Keys.homeHidden) ?? []).compactMap(HomeSection.init(rawValue:)))
        recentSearches = defaults.stringArray(forKey: Keys.recentSearches) ?? []
        // Someone who already set the app up before setup existed shouldn't be walked through it.
        let configured = DebridService(rawValue: defaults.string(forKey: Keys.service) ?? "").map { $0 != .none } ?? false
        setupFinished = defaults.object(forKey: Keys.setupFinished) as? Bool ?? (configured || !savedAddons.isEmpty)
    }

    /// Home's sections in order, without the hidden ones.
    var visibleHomeSections: [HomeSection] { homeOrder.filter { !homeHidden.contains($0) } }

    func resetHomeLayout() {
        homeOrder = HomeSection.allCases
        homeHidden = []
    }

    func rememberSearch(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        recentSearches = [trimmed] + recentSearches.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }.prefix(9)
    }

    func forgetSearch(_ text: String) { recentSearches.removeAll { $0 == text } }
    func clearRecentSearches() { recentSearches = [] }

    var torrentio: TorrentioConfig {
        TorrentioConfig(
            service: debridService, key: debridKey, providers: providers,
            excludedQualities: excludedQualities, sort: sort, maxSizeGB: maxSizeGB, cachedOnly: cachedOnly
        )
    }

    var isDebridConfigured: Bool { torrentio.hasDebrid }

    /// Torrentio needs a debrid service to give playable links; an addon may not.
    var canFindSources: Bool { isDebridConfigured || addons.contains(where: \.enabled) }

    var sourceQuery: SourceQuery { SourceQuery(torrentio: torrentio, addons: addons) }

    private enum Keys {
        static let service = "debrid.service"
        static let debridKey = "debrid.key"
        static let providers = "torrentio.providers"
        static let excluded = "torrentio.excludedQualities"
        static let sort = "torrentio.sort"
        static let maxSize = "torrentio.maxSizeGB"
        static let cachedOnly = "torrentio.cachedOnly"
        static let subtitleLanguage = "player.subtitleLanguage"
        static let audioLanguage = "player.audioLanguage"
        static let autoplaySubtitles = "player.autoplaySubtitles"
        static let autoPlayBest = "playback.autoPlayBest"
        static let addons = "sources.addons"
        static let prepareAhead = "playback.prepareAhead"
        static let subtitleScale = "subtitles.scale"
        static let subtitleStyle = "subtitles.style"
        static let subtitleColor = "subtitles.color"
        static let onlineSubtitles = "subtitles.online"
        static let skipButtons = "player.skipButtons"
        static let autoPlayNext = "player.autoPlayNext"
        static let accent = "appearance.accent"
        static let posterSize = "appearance.posterSize"
        static let showRatings = "appearance.showRatings"
        static let heroAutoAdvance = "appearance.heroAutoAdvance"
        static let homeOrder = "home.order"
        static let homeHidden = "home.hidden"
        static let setupFinished = "setup.finished"
        static let recentSearches = "search.recent"
    }
}

enum SubtitleStyle: String, CaseIterable, Identifiable {
    case outline, shadow, box
    var id: String { rawValue }
    var title: String {
        switch self {
        case .outline: return "Outline"
        case .shadow: return "Drop shadow"
        case .box: return "Dark box"
        }
    }
}

enum SubtitleColor: String, CaseIterable, Identifiable {
    case white, yellow, cyan
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum PosterSize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var scale: CGFloat {
        switch self {
        case .small: return 0.84
        case .medium: return 1
        case .large: return 1.2
        }
    }
}

/// The parts Home is built from. Each can be hidden or moved under Settings → Home Screen.
enum HomeSection: String, CaseIterable, Identifiable, Codable {
    case hero, waiting, continueWatching, newEpisodes, myList
    case popularMovies, popularSeries, newMovies, topMovies, topSeries, newSeries
    case sciFi, animation, crimeSeries, comedy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hero: return "Featured"
        case .waiting: return "Waiting on You"
        case .continueWatching: return "Continue Watching"
        case .newEpisodes: return "New Episodes"
        case .myList: return "My List"
        case .popularMovies: return "Popular Movies"
        case .popularSeries: return "Popular Series"
        case .newMovies: return "New Movies"
        case .topMovies: return "Top Rated Movies"
        case .topSeries: return "Top Rated Series"
        case .newSeries: return "New Series"
        case .sciFi: return "Sci-Fi"
        case .animation: return "Animation"
        case .crimeSeries: return "Crime Series"
        case .comedy: return "Comedy"
        }
    }

    var systemImage: String {
        switch self {
        case .hero: return "sparkles.rectangle.stack"
        case .waiting: return "bell.badge"
        case .continueWatching: return "play.circle"
        case .newEpisodes: return "calendar.badge.clock"
        case .myList: return "bookmark"
        default: return catalogue?.0 == .series ? "tv" : "film"
        }
    }

    /// What a catalogue row lists; nil for the sections built from your own library.
    var catalogue: (MediaKind, Cinemeta.Catalog, String?)? {
        let year = String(Calendar.current.component(.year, from: Date()))
        switch self {
        case .popularMovies: return (.movie, .popular, nil)
        case .popularSeries: return (.series, .popular, nil)
        case .newMovies: return (.movie, .newest, year)
        case .newSeries: return (.series, .newest, year)
        case .topMovies: return (.movie, .topRated, nil)
        case .topSeries: return (.series, .topRated, nil)
        case .sciFi: return (.movie, .popular, "Sci-Fi")
        case .animation: return (.movie, .popular, "Animation")
        case .crimeSeries: return (.series, .popular, "Crime")
        case .comedy: return (.movie, .popular, "Comedy")
        default: return nil
        }
    }
}
