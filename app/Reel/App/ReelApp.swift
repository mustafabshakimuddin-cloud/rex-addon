import SwiftUI
import AVFoundation
import UIKit
import UserNotifications
import CoreSpotlight

/// Hands the background download session's wake-up to the download store, and notification taps
/// to the router.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static var pendingBackgroundCompletion: (() -> Void)?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == DownloadStore.sessionIdentifier else {
            completionHandler()
            return
        }
        Self.pendingBackgroundCompletion = completionHandler
    }

    /// While the app is open, a notification shows as a banner too.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// A tapped notification opens its title.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let id = info["title"] as? String, let kind = (info["kind"] as? String).flatMap(MediaKind.init(rawValue:)) else { return }
        await MainActor.run { AppStores.current?.router.open(MediaItem.placeholder(id: id, kind: kind)) }
    }
}

/// The app's long-lived stores, built in dependency order once.
@MainActor
final class AppStores {
    /// The one set of stores, for work that starts outside the view tree: notification taps,
    /// background refreshes, Shortcuts.
    static var current: AppStores?

    let settings = AppSettings()
    let library = Library()
    let memory = SourceMemory()
    let downloads = DownloadStore()
    let trakt = TraktStore()
    let router = AppRouter()
    let alerts = AlertCenter()
    let upcoming = UpcomingStore()
    let lists = ListsStore()
    let profiles = ProfileStore()
    lazy var playback = PlaybackCenter(memory: memory, downloads: downloads)

    init() {
        // The profile in use is settled before Trakt syncs, so its account fills its library.
        if !profiles.current.isDefault { switchProfile(to: profiles.current) }
        trakt.attach(library)
        let alerts = alerts
        let settings = settings
        downloads.onEvent = { event in
            switch event {
            case let .finished(item):
                alerts.post("Downloaded", message: item.target.displayTitle, level: .success, action: .openDownloads)
                if settings.notifyDownloads { Notifier.downloadFinished(item) }
            case let .failed(item, message):
                alerts.post("Download failed", message: "\(item.target.displayTitle): \(message)", level: .problem, action: .openDownloads)
            }
        }
        if !JSONFile.unreadableFiles.isEmpty {
            alerts.post("Some saved data couldn't be read",
                        message: "It was kept aside, not deleted. Restore a backup in Settings if anything is missing.",
                        level: .warning, action: .openStatus)
        }
        Self.current = self
    }

    /// Becomes someone else: their library, lists, player choices and Trakt account.
    func switchProfile(to profile: Profile) {
        playback.session = nil
        playback.cancel()
        profiles.select(profile)
        library.load(from: profile.file("library"))
        library.kidsOnly = profile.isKids
        lists.load(from: profile.file("lists"))
        trakt.switchProfile(profile)
        router.homePath = NavigationPath()
        router.libraryPath = NavigationPath()
    }

    /// Back in the foreground: sync, tidy downloads, and look at the debrid plan once a day.
    func becameActive() {
        if let completion = AppDelegate.pendingBackgroundCompletion {
            downloads.backgroundCompletion = completion
            AppDelegate.pendingBackgroundCompletion = nil
        }
        Task { await trakt.sync() }
        let library = library
        downloads.pruneWatched(olderThan: settings.deleteWatchedDownloadsAfterDays) { target in
            guard let entry = library.progress(for: target), entry.isFinished else { return nil }
            return entry.updatedAt
        }
        refreshDebridAccount()
    }

    func wentToBackground() {
        library.saveNow()
        lists.saveNow()
        memory.saveNow()
        if settings.notifyNewEpisodes { Notifier.scheduleRefresh() }
    }

    private func refreshDebridAccount() {
        let config = settings.torrentio
        guard config.hasDebrid, DebridAccount.supports(config.service) else { return }
        if let checked = settings.debridAccount?.checkedAt, Date().timeIntervalSince(checked) < 86_400 { return }
        Task {
            guard let info = try? await DebridAccount.info(service: config.service, key: config.key) else { return }
            settings.debridAccount = info
        }
    }

    /// The background refresh: new and upcoming episodes, and their notifications.
    func backgroundRefresh() async {
        Notifier.scheduleRefresh()
        guard settings.notifyNewEpisodes else { return }
        await upcoming.refresh(library, force: true)
        await Notifier.scheduleEpisodes(upcoming.upcoming)
    }

    /// Opens what a link names: `reel://title/tt0111161?type=movie`, an IMDb title link, or a
    /// Spotlight or Handoff result.
    func open(_ url: URL) {
        guard let (id, kind) = Self.title(in: url) else { return }
        router.open(MediaItem.placeholder(id: id, kind: kind))
    }

    nonisolated static func title(in url: URL) -> (String, MediaKind)? {
        let text = url.absoluteString
        guard let range = text.range(of: #"tt\d{5,10}"#, options: .regularExpression) else { return nil }
        let id = String(text[range])
        let type = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "type" }?.value
        let kind = MediaKind(rawValue: type ?? "") ?? (text.contains("/series/") || text.contains("/tv/") ? .series : .movie)
        return (id, kind)
    }
}

extension MediaItem {
    /// A title known only by its id, as links and notifications give it. The title page fills
    /// in the rest from Cinemeta.
    static func placeholder(id: String, kind: MediaKind) -> MediaItem {
        MediaItem(id: id, kind: kind, name: "",
                  poster: URL(string: "https://images.metahub.space/poster/medium/\(id)/img"),
                  background: URL(string: "https://images.metahub.space/background/medium/\(id)/img"),
                  logo: URL(string: "https://images.metahub.space/logo/medium/\(id)/img"))
    }
}

@main
struct ReelApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings: AppSettings
    @StateObject private var library: Library
    @StateObject private var playback: PlaybackCenter
    @StateObject private var router: AppRouter
    @StateObject private var memory: SourceMemory
    @StateObject private var downloads: DownloadStore
    @StateObject private var trakt: TraktStore
    @StateObject private var alerts: AlertCenter
    @StateObject private var upcoming: UpcomingStore
    @StateObject private var lists: ListsStore
    @StateObject private var profiles: ProfileStore
    @Environment(\.scenePhase) private var scenePhase
    private let stores: AppStores

    init() {
        // Play sound with the silent switch on, like any video app.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        let stores = AppStores()
        self.stores = stores
        _settings = StateObject(wrappedValue: stores.settings)
        _library = StateObject(wrappedValue: stores.library)
        _playback = StateObject(wrappedValue: stores.playback)
        _router = StateObject(wrappedValue: stores.router)
        _memory = StateObject(wrappedValue: stores.memory)
        _downloads = StateObject(wrappedValue: stores.downloads)
        _trakt = StateObject(wrappedValue: stores.trakt)
        _alerts = StateObject(wrappedValue: stores.alerts)
        _upcoming = StateObject(wrappedValue: stores.upcoming)
        _lists = StateObject(wrappedValue: stores.lists)
        _profiles = StateObject(wrappedValue: stores.profiles)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(library)
                .environmentObject(playback)
                .environmentObject(router)
                .environmentObject(memory)
                .environmentObject(downloads)
                .environmentObject(trakt)
                .environmentObject(alerts)
                .environmentObject(upcoming)
                .environmentObject(lists)
                .environmentObject(profiles)
                .preferredColorScheme(.dark)
                .tint(settings.accent.accent)
                .onOpenURL { stores.open($0) }
                .onContinueUserActivity(TitleActivity.type) { activity in
                    if let id = activity.userInfo?["id"] as? String,
                       let kind = (activity.userInfo?["kind"] as? String).flatMap(MediaKind.init(rawValue:)) {
                        router.open(MediaItem.placeholder(id: id, kind: kind))
                    }
                }
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    if let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                       let url = URL(string: identifier) {
                        stores.open(url)
                    }
                }
        }
        .commands { AppCommands(router: router) }
        .backgroundTask(.appRefresh(Notifier.refreshTask)) {
            await stores.backgroundRefresh()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: stores.becameActive()
            case .background: stores.wentToBackground()
            default: library.saveNow()
            }
        }
    }
}

/// Handoff: the title open on one device can be picked up on another.
enum TitleActivity {
    static let type = "community.reel.app.title"
}
