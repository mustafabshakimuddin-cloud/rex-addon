import SwiftUI
import AVFoundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import UserNotifications
#if !os(tvOS)
import CoreSpotlight
#endif

#if os(macOS)
/// The Mac: notification taps go to the router, and everything is saved before the app quits.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static var pendingBackgroundCompletion: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppStores.current?.wentToBackground()
    }

    /// Closing the last window leaves the app running, as Mac apps do; the Dock icon opens it again.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let id = info["title"] as? String, let kind = (info["kind"] as? String).flatMap(MediaKind.init(rawValue:)) else { return }
        await MainActor.run { AppStores.current?.router.open(MediaItem.placeholder(id: id, kind: kind)) }
    }
}
#else
/// Hands the background download session's wake-up to the download store, and notification taps
/// to the router.
@MainActor
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

    #if os(iOS)
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
    #endif
}
#endif

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
    let downloadActivities = DownloadActivities()

    init() {
        // The profile in use is settled before Trakt syncs, so its account fills its library.
        if !profiles.current.isDefault { switchProfile(to: profiles.current) }
        trakt.attach(library)
        let alerts = alerts
        let settings = settings
        let activities = downloadActivities
        downloads.onProgress = { item, speed in activities.progress(item, speed: speed) }
        downloads.onEvent = { event in
            switch event {
            case let .finished(item):
                activities.end(item, finished: true)
                alerts.post("Downloaded", message: item.target.displayTitle, level: .success, action: .openDownloads)
                if settings.notifyDownloads { Notifier.downloadFinished(item) }
            case let .failed(item, message):
                activities.end(item, finished: false)
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
        let library = library, upcoming = upcoming
        let done = BackgroundTime.begin("Widgets")
        Task {
            await WidgetPublisher.publish(library: library, upcoming: upcoming)
            done()
        }
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
        if resume(url) { return }
        guard let (id, kind) = Self.title(in: url) else { return }
        router.open(MediaItem.placeholder(id: id, kind: kind))
    }

    /// `reel://resume/<video id>`: plays that entry of Continue Watching, as a widget asks.
    private func resume(_ url: URL) -> Bool {
        guard url.host == "resume" else { return false }
        let videoID = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        guard let entry = library.continueWatching.first(where: { $0.id == videoID }) else { return false }
        router.tab = .home
        playback.play(entry.target, settings: settings, library: library, automatic: true)
        return true
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
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #else
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @State private var settings: AppSettings
    @State private var library: Library
    @State private var playback: PlaybackCenter
    @State private var router: AppRouter
    @State private var memory: SourceMemory
    @State private var downloads: DownloadStore
    @State private var trakt: TraktStore
    @State private var alerts: AlertCenter
    @State private var upcoming: UpcomingStore
    @State private var lists: ListsStore
    @State private var profiles: ProfileStore
    @Environment(\.scenePhase) private var scenePhase
    private let stores: AppStores

    init() {
        #if !os(macOS)
        // Play sound with the silent switch on, like any video app.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        #endif
        let stores = AppStores()
        self.stores = stores
        _settings = State(wrappedValue: stores.settings)
        _library = State(wrappedValue: stores.library)
        _playback = State(wrappedValue: stores.playback)
        _router = State(wrappedValue: stores.router)
        _memory = State(wrappedValue: stores.memory)
        _downloads = State(wrappedValue: stores.downloads)
        _trakt = State(wrappedValue: stores.trakt)
        _alerts = State(wrappedValue: stores.alerts)
        _upcoming = State(wrappedValue: stores.upcoming)
        _lists = State(wrappedValue: stores.lists)
        _profiles = State(wrappedValue: stores.profiles)
    }

    var body: some Scene {
        WindowGroup {
            withStores(RootView())
                .onOpenURL { stores.open($0) }
                .onContinueUserActivity(TitleActivity.type) { activity in
                    if let id = activity.userInfo?["id"] as? String,
                       let kind = (activity.userInfo?["kind"] as? String).flatMap(MediaKind.init(rawValue:)) {
                        router.open(MediaItem.placeholder(id: id, kind: kind))
                    }
                }
                #if !os(tvOS)
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    if let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                       let url = URL(string: identifier) {
                        stores.open(url)
                    }
                }
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 820)
        #endif
        #if !os(tvOS)
        .commands { AppCommands(router: router) }
        #endif
        #if !os(macOS)
        .backgroundTask(.appRefresh(Notifier.refreshTask)) {
            await stores.backgroundRefresh()
        }
        #endif
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: stores.becameActive()
            case .background: stores.wentToBackground()
            default: library.saveNow()
            }
        }

        #if os(macOS)
        // The player is a window of its own on the Mac: it can be resized, moved to another
        // display and made full screen while the library stays open behind it.
        Window("Player", id: "player") {
            withStores(PlayerWindow())
        }
        .defaultSize(width: 1280, height: 720)
        .windowResizability(.contentMinSize)
        // A player left open at quit isn't reopened, empty, at the next launch.
        .restorationBehavior(.disabled)
        #endif
    }

    /// The stores every screen reads, and the app's look.
    private func withStores<Content: View>(_ content: Content) -> some View {
        content
            .environment(settings)
            .environment(library)
            .environment(playback)
            .environment(router)
            .environment(memory)
            .environment(downloads)
            .environment(trakt)
            .environment(alerts)
            .environment(upcoming)
            .environment(lists)
            .environment(profiles)
            .preferredColorScheme(.dark)
            .tint(settings.accent.accent)
            #if os(macOS)
            // Grouped sections as on iPhone; the Mac's default form lines labels up in two columns.
            .formStyle(.grouped)
            #endif
    }
}

/// Handoff: the title open on one device can be picked up on another.
enum TitleActivity {
    static let type = "community.reel.app.title"
}
