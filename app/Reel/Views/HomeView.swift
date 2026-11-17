import SwiftUI

@MainActor
final class HomeModel: ObservableObject {
    struct Shelf: Identifiable {
        let id: String
        let title: String
        var items: [MediaItem]
    }

    @Published var hero: [MediaItem] = []
    @Published var shelves: [Shelf] = []
    @Published var error: String?
    @Published var isLoading = false

    private static let plan: [(String, MediaKind, Cinemeta.Catalog, String?)] = [
        ("Popular Movies", .movie, .popular, nil),
        ("Popular Series", .series, .popular, nil),
        ("Top Rated Movies", .movie, .topRated, nil),
        ("Top Rated Series", .series, .topRated, nil),
        ("Sci-Fi", .movie, .popular, "Sci-Fi"),
        ("Animation", .movie, .popular, "Animation"),
        ("Crime Series", .series, .popular, "Crime"),
        ("Comedy", .movie, .popular, "Comedy"),
    ]

    func load() async {
        guard shelves.isEmpty, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let results = await withTaskGroup(of: (Int, [MediaItem]).self) { group in
            for (index, entry) in Self.plan.enumerated() {
                group.addTask {
                    let items = (try? await Cinemeta.catalog(entry.1, entry.2, genre: entry.3)) ?? []
                    return (index, items)
                }
            }
            var collected: [Int: [MediaItem]] = [:]
            for await (index, items) in group { collected[index] = items }
            return collected
        }
        shelves = Self.plan.enumerated().compactMap { index, entry in
            guard let items = results[index], !items.isEmpty else { return nil }
            return Shelf(id: entry.0, title: entry.0, items: items)
        }
        let movies = results[0] ?? [], series = results[1] ?? []
        hero = Array(zip(movies.prefix(4), series.prefix(4)).flatMap { [$0, $1] }.filter { $0.background != nil }.prefix(6))
        error = shelves.isEmpty ? "Couldn't reach the catalogue. Check your connection and pull to refresh." : nil
    }

    func reload() async {
        shelves = []
        await load()
    }
}

struct HomeView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var playback: PlaybackCenter
    @EnvironmentObject private var router: AppRouter
    @Environment(\.horizontalSizeClass) private var sizeClass
    @StateObject private var model = HomeModel()
    @State private var width: CGFloat = 390

    var body: some View {
        let metrics = CardMetrics(sizeClass)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                if !model.hero.isEmpty {
                    HeroCarousel(items: model.hero, width: width)
                } else if model.isLoading {
                    Rectangle().fill(Theme.surface).frame(height: heroHeight).redacted(reason: .placeholder)
                }

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
                            Button(role: .destructive) { library.clearProgress(entry) } label: { Label("Remove", systemImage: "xmark") }
                        }
                    }
                }

                if !library.watchlist.isEmpty {
                    ShelfRow(title: "My List", items: library.watchlist) { item in
                        NavigationLink(value: item) { PosterCard(item: item, width: metrics.poster) }.buttonStyle(.plain)
                    }
                }

                ForEach(model.shelves) { shelf in
                    ShelfRow(title: shelf.title, items: shelf.items) { item in
                        NavigationLink(value: item) { PosterCard(item: item, width: metrics.poster) }.buttonStyle(.plain)
                    }
                }

                if let error = model.error {
                    StateMessage(title: "Offline", message: error, systemImage: "wifi.slash", actionTitle: "Retry") {
                        Task { await model.reload() }
                    }
                }
            }
            .padding(.bottom, 40)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .ignoresSafeArea(edges: .top)
        .background(Theme.Backdrop())
        .navigationDestination(for: MediaItem.self) { DetailView(item: $0) }
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .topTrailing) {
            Button { router.showingSettings = true } label: {
                Image(systemName: "gearshape.fill").font(.headline).frame(width: 22, height: 22)
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Settings")
            .padding(.trailing, 16)
            .padding(.top, 4)
        }
        .task { await model.load() }
        .refreshable { await model.reload() }
    }

    private var heroHeight: CGFloat { HeroCarousel.height(for: width) }
}

struct HeroCarousel: View {
    let items: [MediaItem]
    let width: CGFloat
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var playback: PlaybackCenter
    @State private var selection: String?

    /// Taller on narrow screens (poster-like), wider and shallower when the window is wide.
    static func height(for width: CGFloat) -> CGFloat {
        width < 600 ? min(width * 1.25, 620) : min(max(width * 0.48, 420), 620)
    }

    var body: some View {
        let height = Self.height(for: width)
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
        .task(id: items.map(\.id)) {
            // Gentle auto-advance; any swipe simply moves the position it continues from.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 7_000_000_000)
                guard !Task.isCancelled, !items.isEmpty else { return }
                let current = items.firstIndex { $0.id == selection } ?? 0
                withAnimation(.easeInOut(duration: 0.6)) { selection = items[(current + 1) % items.count].id }
            }
        }
    }

    static func subtitle(for item: MediaItem) -> String {
        var parts = [item.kind.singular]
        if let year = item.year { parts.append(year) }
        parts.append(contentsOf: item.genres.prefix(2))
        return parts.joined(separator: " · ")
    }

    private func slide(_ item: MediaItem, height: CGFloat) -> some View {
        let wide = width >= 600
        return ZStack(alignment: .bottomLeading) {
            RemoteImage(url: wide ? (item.background ?? item.poster) : (item.poster ?? item.background))
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
