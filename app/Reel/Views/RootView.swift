import SwiftUI

enum AppTab: Hashable {
    case home, movies, series, library, search
}

/// App-wide navigation requests that aren't owned by one screen.
@MainActor
final class AppRouter: ObservableObject {
    @Published var showingSettings = false
    @Published var homePath = NavigationPath()
}

struct RootView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var playback: PlaybackCenter
    @EnvironmentObject private var router: AppRouter
    @State private var tab: AppTab = .home

    var body: some View {
        // A system TabView, not a hand-drawn bar: iOS 27 gives it Liquid Glass, and on the
        // unfolded iPhone Duo (and iPad) the adaptable style turns it into a side rail/sidebar.
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                NavigationStack(path: $router.homePath) { HomeView() }
            }
            Tab("Movies", systemImage: "film", value: AppTab.movies) {
                NavigationStack { BrowseView(kind: .movie) }
            }
            Tab("Series", systemImage: "tv", value: AppTab.series) {
                NavigationStack { BrowseView(kind: .series) }
            }
            Tab("Library", systemImage: "rectangle.stack.fill", value: AppTab.library) {
                NavigationStack { LibraryView() }
            }
            Tab(value: AppTab.search, role: .search) {
                NavigationStack { SearchView() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        .overlay(alignment: .bottom) { preparingHUD }
        // Five tabs fit an iPhone tab bar without a "More" tab; Settings is a gear and a sheet.
        .sheet(isPresented: $router.showingSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        // A symbol, not just a word: on iPhone Duo's outer display the bar is a
                        // vertical rail, and a text-only item leaves that rail standing empty.
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done", systemImage: "checkmark") { router.showingSettings = false }
                        }
                    }
            }
        }
        .sheet(item: $playback.choosingSource) { target in
            SourcesSheet(target: target)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $playback.session) { session in
            PlayerView(session: session)
        }
        .task { ScreenshotTour.run(tab: $tab, router: router, playback: playback) }
        .alert("Couldn't play", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(playback.errorMessage ?? "")
        }
        .alert("Add a debrid service", isPresented: $playback.needsDebridSetup) {
            Button("Open Settings") { router.showingSettings = true }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Streams play through a debrid service such as Real-Debrid, or through a Stremio addon you add. Set one up in Settings.")
        }
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

/// Opens one screen at launch when CI passes `-ReelShot <screen>`, so the simulator job can
/// screenshot every screen on every display. Does nothing otherwise.
@MainActor
enum ScreenshotTour {
    static func run(tab: Binding<AppTab>, router: AppRouter, playback: PlaybackCenter) {
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
            case "movies": tab.wrappedValue = .movies
            case "series": tab.wrappedValue = .series
            case "library": tab.wrappedValue = .library
            case "search": tab.wrappedValue = .search
            case "settings": router.showingSettings = true
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
