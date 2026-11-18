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
        addons = (defaults.data(forKey: Keys.addons)).flatMap { try? JSONDecoder().decode([StreamAddon].self, from: $0) } ?? []
        prepareAhead = defaults.object(forKey: Keys.prepareAhead) as? Bool ?? false
        subtitleScale = defaults.object(forKey: Keys.subtitleScale) as? Double ?? 1
        subtitleStyle = SubtitleStyle(rawValue: defaults.string(forKey: Keys.subtitleStyle) ?? "") ?? .outline
        subtitleColor = SubtitleColor(rawValue: defaults.string(forKey: Keys.subtitleColor) ?? "") ?? .white
        searchOnlineSubtitles = defaults.object(forKey: Keys.onlineSubtitles) as? Bool ?? true
        showSkipButtons = defaults.object(forKey: Keys.skipButtons) as? Bool ?? true
        autoPlayNext = defaults.object(forKey: Keys.autoPlayNext) as? Bool ?? true
    }

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
