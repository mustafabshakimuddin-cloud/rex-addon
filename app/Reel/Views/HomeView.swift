import SwiftUI

@MainActor
final class HomeModel: ObservableObject {
    @Published private(set) var rows: [HomeSection: [MediaItem]] = [:]
    @Published private(set) var hero: [MediaItem] = []
    @Published var error: String?
    @Published private(set) var isLoading = false

    /// Fetches the catalogue rows Home shows that aren't loaded yet. The featured carousel draws
    /// on the popular rows, so those load whenever it is shown, even when their own rows are hidden.
    func load(_ sections: [HomeSection]) async {
        var wanted = sections.filter { $0.catalogue != nil }
        if sections.contains(.hero) { wanted += [.popularMovies, .popularSeries] }
        let missing = Array(Set(wanted)).filter { rows[$0] == nil }
        guard !missing.isEmpty, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let results = await withTaskGroup(of: (HomeSection, [MediaItem]?).self) { group in
            for section in missing {
                guard let source = section.catalogue else { continue }
                group.addTask { (section, try? await Cinemeta.catalog(source.0, source.1, genre: source.2)) }
            }
            var collected: [HomeSection: [MediaItem]] = [:]
            for await (section, items) in group { if let items { collected[section] = items } }
            return collected
        }
        rows.merge(results) { _, new in new }
        if hero.isEmpty {
            let movies = rows[.popularMovies] ?? [], series = rows[.popularSeries] ?? []
            hero = Array(zip(movies.prefix(4), series.prefix(4)).flatMap { [$0, $1] }.filter { $0.background != nil }.prefix(6))
        }
        error = rows.isEmpty ? "Couldn't reach the catalogue. Check your connection and pull to refresh." : nil
    }

    func reload(_ sections: [HomeSection]) async {
        rows = [:]
        hero = []
        await load(sections)
    }
}

struct HomeView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var playback: PlaybackCenter
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var trakt: TraktStore
    @EnvironmentObject private var alerts: AlertCenter
    @EnvironmentObject private var upcoming: UpcomingStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.cardScale) private var cardScale
    @StateObject private var model = HomeModel()
    @State private var width: CGFloat = 390
    @State private var height: CGFloat = 844

    private var sections: [HomeSection] { settings.visibleHomeSections }
    /// The featured carousel runs under the status bar; anything else starts below a title.
    private var heroFirst: Bool { sections.first == .hero && (!model.hero.isEmpty || model.isLoading) }

    var body: some View {
        let metrics = CardMetrics(sizeClass, scale: cardScale)
        let attention = Attention(settings: settings, library: library, trakt: trakt, upcoming: upcoming)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                if !heroFirst {
                    Text("Home").font(.largeTitle.weight(.bold))
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                }
                ForEach(sections) { section in
                    sectionView(section, metrics: metrics, attention: attention)
                }

                if let error = model.error {
                    StateMessage(title: "Offline", message: error, systemImage: "wifi.slash", actionTitle: "Retry") {
                        Task { await model.reload(sections) }
                    }
                }
                if sections.isEmpty {
                    StateMessage(title: "Home is empty", message: "Every section is hidden. Choose what Home shows in Settings.",
                                 systemImage: "square.dashed", actionTitle: "Home Screen Settings") {
                        router.openSettings(.homeScreen)
                    }
                }
            }
            .padding(.bottom, 40)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { width = $0.width; height = $0.height }
        .ignoresSafeArea(edges: heroFirst ? .top : [])
        .background(Theme.Backdrop())
        .scrollsToTopOnRetap(.home)
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .topTrailing) {
            Button { router.openSettings() } label: {
                Image(systemName: "gearshape.fill").font(.headline).frame(width: 22, height: 22)
            }
            .buttonStyle(.glass)
            .overlay(alignment: .topTrailing) {
                if Attention.settingsNeedAttention(settings: settings, trakt: trakt, alerts: alerts) {
                    AttentionDot().offset(x: 2, y: -2)
                }
            }
            .accessibilityLabel("Settings")
            .padding(.trailing, 16)
            .padding(.top, 4)
        }
        .task(id: sections) { await model.load(sections) }
        .refreshable {
            await model.reload(sections)
            await upcoming.refresh(library, force: true)
        }
    }

    private var heroHeight: CGFloat { min(HeroCarousel.height(for: width), height * 0.66) }

    @ViewBuilder
    private func sectionView(_ section: HomeSection, metrics: CardMetrics, attention: Attention) -> some View {
        switch section {
        case .hero:
            if !model.hero.isEmpty {
                HeroCarousel(items: model.hero, width: width, maxHeight: height * 0.66)
            } else if model.isLoading {
                Rectangle().fill(Theme.surface).frame(height: heroHeight).redacted(reason: .placeholder)
            }
        case .waiting:
            AttentionStrip(attention: attention)
        case .continueWatching:
            if !library.continueWatching.isEmpty {
                ShelfRow(title: "Continue Watching", items: library.continueWatching) { entry in
                    Button {
                        playback.play(entry.target, settings: settings, library: library)
                    } label: {
                        ContinueCard(entry: entry, width: metrics.landscape)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        NavigationLink(value: entry.item) { Label("Go to Title", systemImage: "info.circle") }
                        Button { library.markWatched(entry.target) } label: { Label("Mark as Watched", systemImage: "checkmark.circle") }
                        Button(role: .destructive) { library.clearProgress(entry) } label: { Label("Remove", systemImage: "xmark") }
                    }
                }
            }
        case .newEpisodes:
            let fresh = upcoming.newEpisodes(library)
            let waiting = upcoming.unwatchedNew(library)
            if !fresh.isEmpty {
                ShelfRow(title: "New Episodes", subtitle: "Aired in the last two weeks", items: fresh) { entry in
                    let more = (waiting[entry.item.id]?.count ?? 1) - 1
                    Button {
                        playback.play(entry.target, settings: settings, library: library)
                    } label: {
                        BannerCard(item: entry.item, width: metrics.landscape, image: entry.episode.thumbnail ?? entry.item.background,
                                   eyebrow: "New · \(entry.episode.code)" + (more > 0 ? " · +\(more) more" : ""), title: entry.item.name,
                                   subtitle: "\(entry.episode.title) · \(entry.date.formatted(.relative(presentation: .named)))")
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        NavigationLink(value: entry.item) { Label("Go to Series", systemImage: "info.circle") }
                        Button { playback.chooseSource(for: entry.target) } label: { Label("Choose Source", systemImage: "list.bullet.rectangle") }
                        Button { library.markWatched(entry.target) } label: { Label("Mark as Watched", systemImage: "checkmark.circle") }
                    }
                }
            }
        case .myList:
            if !library.watchlist.isEmpty {
                ShelfRow(title: "My List", items: library.watchlist) { item in
                    NavigationLink(value: item) { PosterCard(item: item, width: metrics.poster, mark: library.mark(for: item, downloads: downloads)) }
                        .buttonStyle(.plain)
                }
            }
        default:
            if let items = model.rows[section], !items.isEmpty, let source = section.catalogue {
                ShelfRow(title: section.title, items: items, seeAll: {
                    CatalogGridView(title: section.title, kind: source.0, catalog: source.1, genre: source.2)
                }) { item in
                    NavigationLink(value: item) { PosterCard(item: item, width: metrics.poster, mark: library.mark(for: item, downloads: downloads)) }
                        .buttonStyle(.plain)
                        .contextMenu { TitleContextMenu(item: item) }
                }
            }
        }
    }
}

/// The long-press menu shared by poster cards: list, watched, details.
struct TitleContextMenu: View {
    let item: MediaItem
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var playback: PlaybackCenter
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Button {
            library.toggleWatchlist(item)
        } label: {
            Label(library.isInWatchlist(item) ? "Remove from My List" : "Add to My List",
                  systemImage: library.isInWatchlist(item) ? "minus.circle" : "plus.circle")
        }
        if item.kind == .movie {
            let target = PlaybackTarget(item: item)
            Button { playback.play(target, settings: settings, library: library) } label: { Label("Play", systemImage: "play.fill") }
            if library.isWatched(target) {
                Button { library.markUnwatched(target) } label: { Label("Mark as Unwatched", systemImage: "circle") }
            } else {
                Button { library.markWatched(target) } label: { Label("Mark as Watched", systemImage: "checkmark.circle") }
            }
        }
        NavigationLink(value: item) { Label(item.kind == .movie ? "Details" : "Episodes", systemImage: "info.circle") }
    }
}

struct HeroCarousel: View {
    let items: [MediaItem]
    let width: CGFloat
    /// The outer display of iPhone Duo is short (678 pt); a poster-shaped hero would fill it.
    var maxHeight: CGFloat = .infinity
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var playback: PlaybackCenter
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: String?

    /// Auto-advance only while someone can see it: not in the background, not behind the player.
    private struct AdvanceKey: Equatable { let ids: [String]; let running: Bool }

    /// Taller on narrow screens (poster-like), wider and shallower when the window is wide.
    static func height(for width: CGFloat) -> CGFloat {
        width < 600 ? min(width * 1.25, 620) : min(max(width * 0.48, 420), 620)
    }

    var body: some View {
        let height = min(Self.height(for: width), maxHeight)
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 0) {
                ForEach(items) { item in
                    // One page is exactly the scroll view's visible width, whatever insets the
                    // system applies (the iPhone Duo's vertical rail, iPad sidebars).
                    slide(item, height: height)
                        .frame(height: height)
                        .containerRelativeFrame(.horizontal)
                        .clipped()
                        .id(item.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $selection)
        .frame(height: height)
        // The pages are as wide as the safe area; on iPhone Duo's outer display (and beside the
        // side rail) that stops short of the screen edge. Continue the picture underneath.
        .backgroundExtensionEffect()
        .overlay(alignment: .bottom) {
            HStack(spacing: 6) {
                ForEach(items) { item in
                    Capsule().fill(item.id == (selection ?? items.first?.id) ? Color.white : Color.white.opacity(0.3))
                        .frame(width: item.id == (selection ?? items.first?.id) ? 18 : 6, height: 6)
                }
            }
            .animation(.snappy, value: selection)
            .padding(.bottom, 10)
        }
        .task(id: AdvanceKey(ids: items.map(\.id), running: autoAdvance)) {
            // Gentle auto-advance; any swipe simply moves the position it continues from.
            guard autoAdvance else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 7_000_000_000)
                guard !Task.isCancelled, !items.isEmpty else { return }
                let current = items.firstIndex { $0.id == selection } ?? 0
                withAnimation(.easeInOut(duration: 0.6)) { selection = items[(current + 1) % items.count].id }
            }
        }
    }

    private var autoAdvance: Bool { settings.heroAutoAdvance && scenePhase == .active && playback.session == nil }

    static func subtitle(for item: MediaItem) -> String {
        var parts = [item.kind.singular]
        if let year = item.year { parts.append(year) }
        parts.append(contentsOf: item.genres.prefix(2))
        return parts.joined(separator: " · ")
    }

    private func slide(_ item: MediaItem, height: CGFloat) -> some View {
        let wide = width >= 600
        return ZStack(alignment: .bottomLeading) {
            RemoteImage(url: wide ? (item.background ?? item.poster) : (item.poster ?? item.background), targetWidth: width * 0.75)
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                .clipped()
            LinearGradient(stops: [
                .init(color: .clear, location: 0.35),
                .init(color: Theme.background.opacity(0.7), location: 0.72),
                .init(color: Theme.background, location: 1),
            ], startPoint: .top, endPoint: .bottom)
            if wide {
                LinearGradient(colors: [Theme.background.opacity(0.8), .clear], startPoint: .leading, endPoint: .center)
            }
            VStack(alignment: wide ? .leading : .center, spacing: 14) {
                TitleLogo(item: item, maxHeight: wide ? 110 : 84)
                    .frame(maxWidth: wide ? 420 : width * 0.75, alignment: wide ? .leading : .center)
                Text(Self.subtitle(for: item))
                    .font(.footnote.weight(.medium)).foregroundStyle(Theme.secondaryText)
                HStack(spacing: 12) {
                    if item.kind == .movie {
                        Button {
                            playback.play(PlaybackTarget(item: item), settings: settings, library: library)
                        } label: {
                            Label("Play", systemImage: "play.fill").font(.headline).padding(.horizontal, 10)
                        }
                        .buttonStyle(.glassProminent)
                    }
                    NavigationLink(value: item) {
                        Label(item.kind == .movie ? "Details" : "Episodes", systemImage: "info.circle").font(.headline)
                    }
                    .buttonStyle(.glass)
                    Button {
                        library.toggleWatchlist(item)
                    } label: {
                        Image(systemName: library.isInWatchlist(item) ? "checkmark" : "plus").font(.headline)
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel(library.isInWatchlist(item) ? "Remove from My List" : "Add to My List")
                }
            }
            .frame(maxWidth: .infinity, alignment: wide ? .leading : .center)
            .padding(.horizontal, wide ? 48 : 20)
            .padding(.bottom, 34)
        }
    }
}
