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
    @Published var autoplaySubtitles: Bool { didSet { defaults.set(autoplaySubtitles, forKey: Keys.autoplaySubtitles) } }
    @Published var autoPlayBest: Bool { didSet { defaults.set(autoPlayBest, forKey: Keys.autoPlayBest) } }

    init() {
        debridService = DebridService(rawValue: defaults.string(forKey: Keys.service) ?? "") ?? .none
        debridKey = Keychain.read(Keys.debridKey) ?? ""
        providers = defaults.stringArray(forKey: Keys.providers) ?? []
        excludedQualities = defaults.stringArray(forKey: Keys.excluded) ?? ["scr", "cam"]
        sort = TorrentioSort(rawValue: defaults.string(forKey: Keys.sort) ?? "") ?? .quality
        maxSizeGB = defaults.object(forKey: Keys.maxSize) as? Int ?? 0
        cachedOnly = defaults.object(forKey: Keys.cachedOnly) as? Bool ?? true
        preferredSubtitleLanguage = defaults.string(forKey: Keys.subtitleLanguage) ?? "eng"
        autoplaySubtitles = defaults.object(forKey: Keys.autoplaySubtitles) as? Bool ?? false
        autoPlayBest = defaults.object(forKey: Keys.autoPlayBest) as? Bool ?? false
    }

    var torrentio: TorrentioConfig {
        TorrentioConfig(
            service: debridService, key: debridKey, providers: providers,
            excludedQualities: excludedQualities, sort: sort, maxSizeGB: maxSizeGB, cachedOnly: cachedOnly
        )
    }

    var isDebridConfigured: Bool { torrentio.hasDebrid }

    private enum Keys {
        static let service = "debrid.service"
        static let debridKey = "debrid.key"
        static let providers = "torrentio.providers"
        static let excluded = "torrentio.excludedQualities"
        static let sort = "torrentio.sort"
        static let maxSize = "torrentio.maxSizeGB"
        static let cachedOnly = "torrentio.cachedOnly"
        static let subtitleLanguage = "player.subtitleLanguage"
        static let autoplaySubtitles = "player.autoplaySubtitles"
        static let autoPlayBest = "playback.autoPlayBest"
    }
}
