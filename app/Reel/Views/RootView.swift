import SwiftUI
#if os(macOS)
import AppKit
#endif

enum AppTab: Hashable {
    case home, explore, calendar, library, search
}

/// Pages inside Settings that other screens can open directly (a Status fix, an alert).
enum SettingsPage: Hashable {
    case status, pickRules, addons, trakt, appearance, homeScreen, offline, backup, profiles
}

/// Pages that hang off Library, and that Home's "Waiting on You" cards open.
enum LibraryPage: Hashable {
    case downloads, history, cloud
}

/// A cast or crew member's page.
struct PersonRoute: Hashable {
    let name: String
}

/// App-wide navigation requests that aren't owned by one screen.
@MainActor
@Observable
final class AppRouter {
    var tab: AppTab = .home
    var showingSettings = false
    var showingSetup = false
    var homePath = NavigationPath()
    var libraryPath = NavigationPath()
    var settingsPath = NavigationPath()
    var explorePath = NavigationPath()
    var calendarPath = NavigationPath()
    var searchPath = NavigationPath()
    var exploreKind: MediaKind = .movie
    /// Raised when the current tab is chosen again: its screen scrolls back to the top.
    private(set) var scrollToTop: AppTab?
    /// Run once the Settings sheet has finished closing.
    private var afterSettings: (() -> Void)?

    /// The tab bar's selection. Choosing the tab already showing goes back to its first screen,
    /// and from there to the top, as in every iOS app.
    var tabSelection: Binding<AppTab> {
        Binding(get: { self.tab }, set: { chosen in
            if chosen == self.tab { self.popToRoot(chosen) } else { self.tab = chosen }
        })
    }

    func popToRoot(_ tab: AppTab) {
        switch tab {
        case .home: if homePath.isEmpty { scrollToTop = .home } else { homePath = NavigationPath() }
        case .explore: if explorePath.isEmpty { scrollToTop = .explore } else { explorePath = NavigationPath() }
        case .calendar: if calendarPath.isEmpty { scrollToTop = .calendar } else { calendarPath = NavigationPath() }
        case .library: if libraryPath.isEmpty { scrollToTop = .library } else { libraryPath = NavigationPath() }
        case .search: if searchPath.isEmpty { scrollToTop = .search } else { searchPath = NavigationPath() }
        }
    }

    func didScrollToTop() { scrollToTop = nil }

    /// Closes Settings, then runs `next` once it is off screen.
    private func closeSettings(then next: @escaping () -> Void) {
        guard showingSettings else { next(); return }
        afterSettings = next
        showingSettings = false
    }

    /// RootView: the Settings sheet has finished closing.
    func settingsDismissed() {
        let next = afterSettings
        afterSettings = nil
        next?()
    }

    /// Words for Search to look up, from a shortcut; Search takes them when it appears.
    var pendingSearch: String?

    func search(_ text: String) {
        closeSettings {
            self.searchPath = NavigationPath()
            self.tab = .search
            self.pendingSearch = text
        }
    }

    /// Opens a title from a link or a shortcut, on the Home tab.
    func open(_ item: MediaItem) {
        closeSettings {
            self.tab = .home
            self.homePath = NavigationPath()
            self.homePath.append(item)
        }
    }

    func openSettings(_ page: SettingsPage? = nil) {
        settingsPath = NavigationPath()
        if let page { settingsPath.append(page) }
        showingSettings = true
    }

    func openLibrary(_ page: LibraryPage) {
        closeSettings {
            self.tab = .library
            self.libraryPath = NavigationPath()
            self.libraryPath.append(page)
        }
    }

    func openSetup() {
        closeSettings { self.showingSetup = true }
    }

    func perform(_ action: AppAlert.Action) {
        switch action {
        case .openDownloads: openLibrary(.downloads)
        case .openStatus: openSettings(.status)
        case .openTrakt: openSettings(.trakt)
        case .openSetup: openSetup()
        }
    }

    func perform(_ fix: HealthCheck.Fix, openURL: OpenURLAction) {
        switch fix {
        case let .settings(page): settingsPath = NavigationPath(); settingsPath.append(page); showingSettings = true
        case .settingsHome: settingsPath = NavigationPath(); showingSettings = true
        case .setup: openSetup()
        case .downloads: openLibrary(.downloads)
        case let .link(url): openURL(url)
        }
    }
}

extension View {
    /// The pages any tab can push: titles, people and the Library's own pages. Registered once at
    /// the root of each tab's stack.
    func appDestinations() -> some View {
        navigationDestination(for: MediaItem.self) { DetailView(item: $0) }
            .navigationDestination(for: PersonRoute.self) { PersonView(name: $0.name) }
            .navigationDestination(for: ListRoute.self) { ListDetailView(route: $0) }
            .navigationDestination(for: LibraryPage.self) { page in
                switch page {
                case .downloads: DownloadsView()
                case .history: HistoryView()
                case .cloud: DebridCloudView()
                }
            }
    }
}

struct RootView: View {
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @Environment(AppSettings.self) private var settings
    @Environment(Library.self) private var library
    @Environment(PlaybackCenter.self) private var playback
    @Environment(AppRouter.self) private var router
    @Environment(TraktStore.self) private var trakt
    @Environment(AlertCenter.self) private var alerts
    @Environment(UpcomingStore.self) private var upcoming

    var body: some View {
        let attention = Attention(settings: settings, library: library, trakt: trakt, upcoming: upcoming)
        // A system TabView, not a hand-drawn bar: iOS 27 gives it Liquid Glass, and on the
        // unfolded iPhone Duo (and iPad) the adaptable style turns it into a side rail/sidebar.
        TabView(selection: router.tabSelection) {
            Tab("Home", systemImage: "house.fill", value: AppTab.home) { homeTab }
                #if !os(tvOS)
                .badge(attention.badgeCount)
                #endif
            Tab("Explore", systemImage: "safari", value: AppTab.explore) { exploreTab }
            Tab("Calendar", systemImage: "calendar", value: AppTab.calendar) { calendarTab }
            Tab("Library", systemImage: "rectangle.stack.fill", value: AppTab.library) { libraryTab }
            Tab(value: AppTab.search, role: .search) { searchTab }
        }
        .tabViewStyle(.sidebarAdaptable)
        #if os(iOS)
        .tabBarMinimizeBehavior(.onScrollDown)
        #endif
        // A new accent colour rebuilds the tabs so every screen picks it up; the sheets and the
        // router's state sit outside and carry on.
        .id(settings.accent)
        .environment(\.cardScale, settings.posterSize.scale)
        .environment(\.showsRatings, settings.showRatings)
        .overlay(alignment: .bottom) { preparingHUD }
        .overlay(alignment: .top) { AlertToast() }
        // Five tabs fit an iPhone tab bar without a "More" tab; Settings is a gear and a sheet
        // (full screen on Apple TV, whose sheets are a narrow panel in the middle of the TV).
        .settingsPresentation(isPresented: Bindable(router).showingSettings, onDismiss: { router.settingsDismissed() }) {
            NavigationStack(path: Bindable(router).settingsPath) {
                SettingsView()
                    .toolbar {
                        // A symbol, not just a word: on iPhone Duo's outer display the bar is a
                        // vertical rail, and a text-only item leaves that rail standing empty.
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done", systemImage: "checkmark") { router.showingSettings = false }
                        }
                    }
            }
            .environment(\.cardScale, settings.posterSize.scale)
            #if os(macOS)
            .frame(minWidth: 640, idealWidth: 720, minHeight: 620, idealHeight: 760)
            #endif
        }
        #if os(macOS)
        // A sheet on the Mac, which has no full-screen covers; the player is a window of its own
        // (ReelMac/PlayerWindow.swift), opened whenever a session starts.
        .sheet(isPresented: Bindable(router).showingSetup) {
            SetupView().frame(minWidth: 620, idealWidth: 680, minHeight: 640, idealHeight: 720)
        }
        .sheet(item: Bindable(playback).choosingSource) { target in
            SourcesSheet(target: target).frame(minWidth: 680, idealWidth: 760, minHeight: 620, idealHeight: 760)
        }
        .onChange(of: playback.session?.id) { _, id in
            if id != nil { openWindow(id: "player") }
        }
        // What needs you, on the Dock icon.
        .onChange(of: attention.badgeCount, initial: true) { _, count in
            NSApplication.shared.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        }
        #else
        .fullScreenCover(isPresented: Bindable(router).showingSetup) {
            SetupView()
        }
        .sourcesPresentation(item: Bindable(playback).choosingSource) { target in
            SourcesSheet(target: target)
                #if os(iOS)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                #endif
        }
        .fullScreenCover(item: Bindable(playback).session, onDismiss: { playback.playerDismissed() }) { session in
            PlayerView(session: session)
        }
        #endif
        .task {
            if ScreenshotTour.isActive {
                ScreenshotTour.run(router: router, playback: playback)
            } else if !settings.setupFinished {
                // First launch: walk through setup before anything else.
                try? await Task.sleep(nanoseconds: 400_000_000)
                router.showingSetup = true
            }
        }
        .task(id: UpcomingStore.followedSeries(library).map(\.id)) {
            await upcoming.refresh(library)
            if settings.notifyNewEpisodes { await Notifier.scheduleEpisodes(upcoming.upcoming) }
            await WidgetPublisher.publish(library: library, upcoming: upcoming)
        }
        .task(id: library.watchlist.map(\.id)) {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            Spotlight.index(library.watchlist)
        }
        .onChange(of: settings.notifyNewEpisodes) { _, on in
            Task {
                if on, await Notifier.requestPermission() {
                    await upcoming.refresh(library)
                    await Notifier.scheduleEpisodes(upcoming.upcoming)
                    Notifier.scheduleRefresh()
                } else {
                    if on { settings.notifyNewEpisodes = false }
                    await Notifier.cancelEpisodes()
                }
            }
        }
        .onChange(of: settings.notifyDownloads) { _, on in
            guard on else { return }
            Task { if !(await Notifier.requestPermission()) { settings.notifyDownloads = false } }
        }
        #if os(tvOS)
        // No banners on Apple TV: what needs you is counted on the app's icon instead.
        .onChange(of: attention.badgeCount, initial: true) { _, count in Notifier.setBadge(count) }
        #endif
        .onChange(of: trakt.syncError) { _, error in
            if let error { alerts.post("Trakt sync stopped", message: error, level: .warning, action: .openTrakt) }
        }
        .alert("Couldn't play", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(playback.errorMessage ?? "")
        }
        .alert("Add a debrid service", isPresented: Bindable(playback).needsDebridSetup) {
            Button("Set Up") { router.openSetup() }
            Button("Open Settings") { router.openSettings() }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Streams play through a debrid service such as Real-Debrid, or through a Stremio addon you add.")
        }
    }

    // Each tab's stack on its own, which keeps the TabView quick to type-check.
    private var homeTab: some View {
        NavigationStack(path: Bindable(router).homePath) { HomeView().appDestinations() }
    }
    private var exploreTab: some View {
        NavigationStack(path: Bindable(router).explorePath) { ExploreView().appDestinations() }
    }
    private var calendarTab: some View {
        NavigationStack(path: Bindable(router).calendarPath) { CalendarView().appDestinations() }
    }
    private var libraryTab: some View {
        NavigationStack(path: Bindable(router).libraryPath) { LibraryView().appDestinations() }
    }
    private var searchTab: some View {
        NavigationStack(path: Bindable(router).searchPath) { SearchView().appDestinations() }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { playback.errorMessage != nil }, set: { if !$0 { playback.errorMessage = nil } })
    }

    @ViewBuilder private var preparingHUD: some View {
        if let target = playback.preparing {
            HStack(spacing: 12) {
                ProgressView().tint(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text(playback.fallbackNotice == nil ? "Preparing stream" : "Trying the next source").font(.subheadline.weight(.semibold))
                    Text(target.displayTitle).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button("Cancel") { playback.cancel() }
                    .buttonStyle(.glass)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: 460)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
            .padding(.horizontal, 16)
            .padding(.bottom, 90)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.spring(duration: 0.35), value: playback.preparing)
        }
    }
}

/// The pop-up for the newest alert: a glass card under the status bar. Tap its button to go where
/// the alert points, swipe it up or wait to dismiss it.
struct AlertToast: View {
    @Environment(AlertCenter.self) private var alerts
    @Environment(AppRouter.self) private var router

    var body: some View {
        ZStack {
            if let alert = alerts.current {
                HStack(spacing: 12) {
                    Image(systemName: alert.systemImage)
                        .font(.title3)
                        .foregroundStyle(tint(alert.level))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(alert.title.localized).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if let message = alert.message {
                            Text(message).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 6)
                    if let action = alert.action, let title = alert.actionTitle {
                        Button(title) {
                            alerts.dismissCurrent()
                            router.perform(action)
                        }
                        .buttonStyle(.glass)
                        .font(.caption.weight(.semibold))
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(maxWidth: 520)
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
                .padding(.horizontal, 16)
                .padding(.top, 6)
                #if !os(tvOS)
                .onTapGesture { alerts.dismissCurrent() }
                .gesture(DragGesture(minimumDistance: 12).onEnded { value in
                    if value.translation.height < -10 { alerts.dismissCurrent() }
                })
                #endif
                .transition(.move(edge: .top).combined(with: .opacity))
                .id(alert.id)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isStaticText)
            }
        }
        .animation(.spring(duration: 0.4), value: alerts.current)
    }

    private func tint(_ level: AppAlert.Level) -> Color {
        switch level {
        case .info: return Theme.accent
        case .success: return Theme.cached
        case .warning: return Theme.warning
        case .problem: return Theme.problem
        }
    }
}

#if !os(tvOS)
/// Keyboard shortcuts for iPad and a hardware keyboard; they appear in the shortcut overlay
/// when ⌘ is held.
struct AppCommands: Commands {
    let router: AppRouter

    var body: some Commands {
        CommandMenu("Go") {
            Button("Home") { router.tab = .home }.keyboardShortcut("1")
            Button("Explore") { router.tab = .explore }.keyboardShortcut("2")
            Button("Calendar") { router.tab = .calendar }.keyboardShortcut("3")
            Button("Library") { router.tab = .library }.keyboardShortcut("4")
            Button("Search") { router.tab = .search }.keyboardShortcut("f")
            Divider()
            Button("History") { router.openLibrary(.history) }.keyboardShortcut("y")
            Button("Status") { router.openSettings(.status) }.keyboardShortcut("s", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { router.openSettings() }.keyboardShortcut(",")
        }
    }
}
#endif

/// Opens one screen at launch when CI passes `-ReelShot <screen>`, so the simulator job can
/// screenshot every screen on every display. Does nothing otherwise.
@MainActor
enum ScreenshotTour {
    static var isActive: Bool { ProcessInfo.processInfo.arguments.contains("-ReelShot") }

    static func run(router: AppRouter, playback: PlaybackCenter) {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-ReelShot"), arguments.indices.contains(index + 1) else { return }
        let series = MediaItem(
            id: "tt0903747", kind: .series, name: "Breaking Bad",
            poster: URL(string: "https://images.metahub.space/poster/medium/tt0903747/img"),
            background: URL(string: "https://images.metahub.space/background/medium/tt0903747/img"),
            logo: URL(string: "https://images.metahub.space/logo/medium/tt0903747/img"),
            year: "2008", rating: "9.5", genres: ["Crime", "Drama"],
            overview: "A chemistry teacher diagnosed with cancer turns to making methamphetamine.")
        let episode = Episode(id: "tt0903747:1:1", season: 1, number: 1, title: "Pilot")
        let target = PlaybackTarget(item: series, episode: episode)
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            switch arguments[index + 1] {
            case "movies", "explore": router.exploreKind = .movie; router.tab = .explore
            case "series": router.exploreKind = .series; router.tab = .explore
            case "calendar": router.tab = .calendar
            case "library": router.tab = .library
            case "downloads": router.openLibrary(.downloads)
            case "history": router.openLibrary(.history)
            case "search": router.tab = .search
            case "settings": router.openSettings()
            case "status": router.openSettings(.status)
            case "appearance": router.openSettings(.appearance)
            case "setup": router.showingSetup = true
            case "person": router.homePath.append(PersonRoute(name: "Bryan Cranston"))
            case "detail": router.homePath.append(series)
            case "sources":
                router.homePath.append(series)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                playback.chooseSource(for: target)
            case "player":
                let source = StreamSource(
                    id: "tour", addon: "Torrentio", addonHost: nil, quality: "1080p", tags: ["HDR"],
                    release: "Sample stream", file: nil, size: "1.2 GB", sizeBytes: 1_288_490_188,
                    seeders: nil, provider: nil, languages: nil, debridTag: nil, cached: true,
                    url: nil, infoHash: nil, fileIndex: nil, bingeGroup: nil)
                if let url = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8") {
                    playback.session = PlayerSession(target: target, url: url, source: source, startAt: nil)
                }
            default: break
            }
        }
    }
}

private extension View {
    /// Settings: a sheet, or a full-screen cover on Apple TV.
    @ViewBuilder func settingsPresentation<Content: View>(isPresented: Binding<Bool>, onDismiss: @escaping () -> Void,
                                                         @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(tvOS)
        fullScreenCover(isPresented: isPresented, onDismiss: onDismiss) { content().background(Theme.Backdrop()) }
        #else
        sheet(isPresented: isPresented, onDismiss: onDismiss, content: content)
        #endif
    }

    /// The source list: a sheet, or a full-screen cover on Apple TV.
    @ViewBuilder func sourcesPresentation<Item: Identifiable, Content: View>(item: Binding<Item?>,
                                                                             @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        #if os(tvOS)
        fullScreenCover(item: item) { content($0).background(Theme.Backdrop()) }
        #else
        sheet(item: item, content: content)
        #endif
    }
}
