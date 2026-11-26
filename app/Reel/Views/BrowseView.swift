import SwiftUI

@MainActor
final class BrowseModel: ObservableObject {
    @Published var items: [MediaItem] = []
    @Published var isLoading = false
    @Published var error: String?
    private var page = 0
    private var exhausted = false
    private var key = ""

    func reset(kind: MediaKind, catalog: Cinemeta.Catalog, genre: String?) async {
        let newKey = "\(kind.rawValue)|\(catalog.rawValue)|\(genre ?? "")"
        guard newKey != key || items.isEmpty else { return }
        key = newKey
        items = []
        page = 0
        exhausted = false
        await loadMore(kind: kind, catalog: catalog, genre: genre)
    }

    func loadMore(kind: MediaKind, catalog: Cinemeta.Catalog, genre: String?) async {
        guard !isLoading, !exhausted else { return }
        isLoading = true
        let requestKey = key
        defer { isLoading = false }
        do {
            let next = try await Cinemeta.catalog(kind, catalog, genre: genre, page: page)
            guard requestKey == key else { return }
            let known = Set(items.map(\.id))
            items += next.filter { !known.contains($0.id) }
            page += 1
            exhausted = next.isEmpty
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// How a grid orders what it has loaded.
enum GridOrder: String, CaseIterable, Identifiable {
    case list, newest, rating
    var id: String { rawValue }
    var title: String {
        switch self {
        case .list: return "List order"
        case .newest: return "Newest first"
        case .rating: return "Highest rated"
        }
    }

    func apply(_ items: [MediaItem]) -> [MediaItem] {
        switch self {
        case .list: return items
        case .newest: return items.sorted { ($0.year ?? "") > ($1.year ?? "") }
        case .rating: return items.sorted { (Double($0.rating ?? "") ?? 0) > (Double($1.rating ?? "") ?? 0) }
        }
    }
}


enum ExploreLayout: String, CaseIterable, Identifiable {
    case rows, grid
    var id: String { rawValue }
    var title: String { self == .rows ? "Rows" : "Grid" }
    var systemImage: String { self == .rows ? "rectangle.split.1x2" : "square.grid.3x3" }
}

/// Films and series in one place. Rows shows a shelf per list and genre to scroll through; Grid
/// shows one list at a time with its filters, loading more as you go.
struct ExploreView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var settings: AppSettings
    @AppStorage("explore.layout") private var layout: ExploreLayout = .rows

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Picker("Type", selection: $router.exploreKind) {
                    ForEach(MediaKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                .padding(.horizontal, 20)

                switch layout {
                case .rows: ExploreRows(kind: router.exploreKind)
                case .grid: ExploreGrid(kind: router.exploreKind)
                }
            }
            .padding(.vertical, 12)
        }
        .background(Theme.Backdrop())
        .scrollsToTopOnRetap(.explore)
        .navigationTitle("Explore")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Layout", selection: $layout) {
                        ForEach(ExploreLayout.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                    }
                    Toggle(isOn: $settings.hideWatched) { Label("Hide Watched Films", systemImage: "eye.slash") }
                } label: {
                    Label("Layout", systemImage: layout.systemImage)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { router.openSettings() } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
            }
        }
    }
}

/// A shelf per list, then one per genre. Each loads as it scrolls into view.
private struct ExploreRows: View {
    let kind: MediaKind

    private struct Shelf: Identifiable {
        let title: String
        let catalog: Cinemeta.Catalog
        let genre: String?
        var id: String { title }
    }

    private var shelves: [Shelf] {
        let year = Cinemeta.recentYears.first
        return [Shelf(title: "Popular", catalog: .popular, genre: nil),
                Shelf(title: "New in \(year ?? "")", catalog: .newest, genre: year),
                Shelf(title: "Top Rated", catalog: .topRated, genre: nil)]
            + Cinemeta.genres(for: kind).map { Shelf(title: $0, catalog: .popular, genre: $0) }
    }

    @EnvironmentObject private var settings: AppSettings

    /// Catalogues from the addons you've added, for this kind of title.
    private struct AddonShelfKey: Identifiable {
        let addon: StreamAddon
        let catalog: AddonCatalog
        var id: String { "\(addon.id)|\(catalog.type)|\(catalog.id)" }
    }

    private var addonShelves: [AddonShelfKey] {
        settings.addons.filter(\.enabled).flatMap { addon in
            (addon.catalogs ?? []).filter { $0.kind == kind }.map { AddonShelfKey(addon: addon, catalog: $0) }
        }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 30) {
            ForEach(shelves) { shelf in
                LazyShelf(title: shelf.title, kind: kind, catalog: shelf.catalog, genre: shelf.genre)
            }
            ForEach(addonShelves) { shelf in
                AddonShelf(addon: shelf.addon, catalog: shelf.catalog)
            }
        }
    }
}

/// One of an addon's catalogues as a shelf, with See All paging through the rest.
struct AddonShelf: View {
    let addon: StreamAddon
    let catalog: AddonCatalog
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.cardScale) private var cardScale
    @State private var loaded: [MediaItem] = []
    @State private var failed = false

    var body: some View {
        let metrics = CardMetrics(sizeClass, scale: cardScale)
        let items = library.shown(loaded, hidingWatched: settings.hideWatched)
        Group {
            if !items.isEmpty {
                ShelfRow(title: catalog.name, subtitle: addon.name, items: items, seeAll: {
                    AddonCatalogGrid(addon: addon, catalog: catalog)
                }) { item in
                    NavigationLink(value: item) { PosterCard(item: item, width: metrics.poster, mark: library.mark(for: item, downloads: downloads)) }
                        .buttonStyle(.plain)
                        .contextMenu { TitleContextMenu(item: item) }
                }
            } else if failed {
                EmptyView()
            } else {
                SectionHeader(title: catalog.name, subtitle: addon.name).padding(.horizontal, 20)
            }
        }
        .task(id: addon.id + catalog.id) {
            do { loaded = Array(try await Addons.catalog(catalog, from: addon).prefix(20)) } catch { failed = true }
        }
    }
}

/// An addon catalogue as a grid, loading the next page as the end comes into view.
struct AddonCatalogGrid: View {
    let addon: StreamAddon
    let catalog: AddonCatalog
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: DownloadStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.cardScale) private var cardScale
    @State private var items: [MediaItem] = []
    @State private var page = 0
    @State private var done = false
    @State private var loading = false

    var body: some View {
        let metrics = CardMetrics(sizeClass, scale: cardScale)
        ScrollView {
            LazyVGrid(columns: metrics.posterColumns, spacing: 22) {
                ForEach(items) { item in
                    NavigationLink(value: item) {
                        PosterCard(item: item, width: metrics.poster, mark: library.mark(for: item, downloads: downloads))
                    }
                    .buttonStyle(.plain)
                    .contextMenu { TitleContextMenu(item: item) }
                    .onAppear { if item.id == items.last?.id { Task { await loadMore() } } }
                }
            }
            .padding(20)
            if loading { ProgressView().padding() }
        }
        .background(Theme.Backdrop())
        .navigationTitle(catalog.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { if items.isEmpty { await loadMore() } }
    }

    private func loadMore() async {
        guard !loading, !done else { return }
        loading = true
        defer { loading = false }
        guard let next = try? await Addons.catalog(catalog, from: addon, page: page) else { done = true; return }
        let known = Set(items.map(\.id))
        let fresh = next.filter { !known.contains($0.id) }
        items += fresh
        page += 1
        done = fresh.isEmpty
    }
}

/// A catalogue shelf that fetches its titles the first time it appears.
struct LazyShelf: View {
    let title: String
    let kind: MediaKind
    let catalog: Cinemeta.Catalog
    let genre: String?
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.cardScale) private var cardScale
    @State private var loaded: [MediaItem] = []
    @State private var failed = false
    @State private var attempt = 0

    private var items: [MediaItem] { library.shown(loaded, hidingWatched: settings.hideWatched) }

    var body: some View {
        let metrics = CardMetrics(sizeClass, scale: cardScale)
        Group {
            if items.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: title).padding(.horizontal, 20)
                    if failed {
                        HStack(spacing: 10) {
                            Text("Couldn't load this row.").font(.footnote).foregroundStyle(Theme.secondaryText)
                            Button("Retry") { attempt += 1 }.font(.footnote.weight(.semibold))
                        }
                        .padding(.horizontal, 20)
                    } else if !loaded.isEmpty {
                        Text("You've watched everything here.").font(.footnote).foregroundStyle(Theme.secondaryText).padding(.horizontal, 20)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(0..<6, id: \.self) { _ in
                                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface)
                                        .frame(width: metrics.poster, height: metrics.poster * 1.5)
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                        .disabled(true)
                    }
                }
            } else {
                ShelfRow(title: title, items: items, seeAll: {
                    CatalogGridView(title: "\(title) \(kind.title)", kind: kind, catalog: catalog, genre: genre)
                }) { item in
                    NavigationLink(value: item) { PosterCard(item: item, width: metrics.poster, mark: library.mark(for: item, downloads: downloads)) }
                        .buttonStyle(.plain)
                        .contextMenu { TitleContextMenu(item: item) }
                }
            }
        }
        .task(id: "\(kind.rawValue)|\(catalog.rawValue)|\(genre ?? "")|\(attempt)") {
            loaded = []
            failed = false
            do {
                loaded = Array(try await Cinemeta.catalog(kind, catalog, genre: genre).prefix(20))
            } catch {
                failed = true
            }
        }
    }
}

/// One list at a time: Popular, New or Top Rated, narrowed by genre (or year, for New).
private struct ExploreGrid: View {
    let kind: MediaKind
    @AppStorage("explore.catalog") private var catalog: Cinemeta.Catalog = .popular
    @State private var genre: String?
    @State private var year: String = Cinemeta.recentYears.first ?? ""
    @State private var order: GridOrder = .list

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("List", selection: $catalog) {
                ForEach(Cinemeta.Catalog.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if catalog.filtersByYear {
                        ForEach(Cinemeta.recentYears, id: \.self) { value in
                            chip(value, selected: year == value) { year = value }
                        }
                    } else {
                        chip("All", selected: genre == nil) { genre = nil }
                        ForEach(Cinemeta.genres(for: kind), id: \.self) { value in
                            chip(value, selected: genre == value) { genre = value }
                        }
                    }
                }
                .padding(.horizontal, 20)
            }

            Picker("Order", selection: $order) {
                ForEach(GridOrder.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .padding(.horizontal, 14)

            CatalogGrid(kind: kind, catalog: catalog, genre: catalog.filtersByYear ? year : genre, order: order)
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy) { action() }
        } label: {
            Text(title).font(.subheadline.weight(.semibold)).padding(.horizontal, 6)
        }
        .buttonStyle(.glass)
        .tint(selected ? Theme.accent : nil)
    }
}

/// A grid of one catalogue list that loads the next page as the last poster appears. Lives inside
/// a ScrollView.
struct CatalogGrid: View {
    let kind: MediaKind
    let catalog: Cinemeta.Catalog
    let genre: String?
    var order: GridOrder = .list
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.cardScale) private var cardScale
    @StateObject private var model = BrowseModel()

    var body: some View {
        let metrics = CardMetrics(sizeClass, scale: cardScale)
        let items = order.apply(library.shown(model.items, hidingWatched: settings.hideWatched))
        VStack(spacing: 18) {
            LazyVGrid(columns: metrics.posterColumns, spacing: 22) {
                ForEach(items) { item in
                    NavigationLink(value: item) {
                        PosterCard(item: item, width: metrics.poster, mark: library.mark(for: item, downloads: downloads))
                    }
                    .buttonStyle(.plain)
                    .contextMenu { TitleContextMenu(item: item) }
                    .onAppear {
                        if item.id == model.items.last?.id {
                            Task { await model.loadMore(kind: kind, catalog: catalog, genre: genre) }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)

            if model.isLoading {
                ProgressView().frame(maxWidth: .infinity).padding()
            } else if let error = model.error, model.items.isEmpty {
                StateMessage(title: "Couldn't load", message: error, actionTitle: "Retry") {
                    Task { await model.reset(kind: kind, catalog: catalog, genre: genre) }
                }
            } else if model.error != nil {
                Button("Couldn't load more. Retry", systemImage: "arrow.clockwise") {
                    Task { await model.loadMore(kind: kind, catalog: catalog, genre: genre) }
                }
                .buttonStyle(.glass)
                .padding()
            } else if model.items.isEmpty {
                StateMessage(title: "Nothing here", message: "This list has no titles right now.", systemImage: "tray")
            }
        }
        .task(id: "\(kind.rawValue)|\(catalog.rawValue)|\(genre ?? "")") {
            await model.reset(kind: kind, catalog: catalog, genre: genre)
        }
    }
}

/// "See All" from a shelf: that list as a full grid.
struct CatalogGridView: View {
    let title: String
    let kind: MediaKind
    let catalog: Cinemeta.Catalog
    let genre: String?

    var body: some View {
        ScrollView {
            CatalogGrid(kind: kind, catalog: catalog, genre: genre)
                .padding(.vertical, 12)
        }
        .background(Theme.Backdrop())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Search

struct SearchView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: DownloadStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.cardScale) private var cardScale
    @State private var query = ""
    @State private var movies: [MediaItem] = []
    @State private var series: [MediaItem] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var attempt = 0
    @State private var scope: SearchScope = .all

    enum SearchScope: String, CaseIterable, Identifiable {
        case all = "All", movies = "Movies", series = "Series", people = "People"
        var id: String { rawValue }
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    /// An IMDb link or id pasted into the field: open that title directly.
    private var linkedTitle: MediaItem? {
        guard let range = trimmed.range(of: #"tt\d{5,10}"#, options: .regularExpression) else { return nil }
        let id = String(trimmed[range])
        let kind: MediaKind = series.contains { $0.id == id } ? .series : .movie
        return MediaItem.placeholder(id: id, kind: kind)
    }

    /// The likeliest match: a title named exactly as typed, otherwise the first one found.
    private var topResult: MediaItem? {
        let all = movies + series
        return all.first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame } ?? (movies.first ?? series.first)
    }

    var body: some View {
        let metrics = CardMetrics(sizeClass, scale: cardScale)
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if trimmed.isEmpty {
                    suggestions
                } else if scope == .people {
                    PersonResults(name: trimmed)
                } else {
                    if let link = linkedTitle {
                        NavigationLink(value: link) {
                            Label("Open \(link.id) from the link", systemImage: "link")
                                .font(.headline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 20)
                    }
                    if let searchError, !isSearching {
                        StateMessage(title: "Couldn't search", message: searchError, systemImage: "wifi.exclamationmark", actionTitle: "Retry") {
                            attempt += 1
                        }
                        .padding(.top, 60)
                    } else if isSearching && movies.isEmpty && series.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                    } else if !isSearching && movies.isEmpty && series.isEmpty {
                        StateMessage(title: "No results", message: "Nothing matches “\(query)”. Try People to search by cast or director.",
                                     systemImage: "magnifyingglass", actionTitle: "Search People") { scope = .people }
                            .padding(.top, 60)
                    }
                    if scope == .all, let top = topResult {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader(title: "Top Result").padding(.horizontal, 20)
                            NavigationLink(value: top) {
                                BannerCard(item: top, width: min(metrics.landscape * 1.5, 520),
                                           eyebrow: top.kind.singular, subtitle: HeroCarousel.subtitle(for: top))
                            }
                            .buttonStyle(.plain)
                            .simultaneousGesture(TapGesture().onEnded { settings.rememberSearch(query) })
                            .padding(.horizontal, 20)
                        }
                    }
                    if scope != .series, !movies.isEmpty { section("Movies", movies, metrics) }
                    if scope != .movies, !series.isEmpty { section("Series", series, metrics) }
                }
            }
            .padding(.vertical, 12)
        }
        .background(Theme.Backdrop())
        .scrollsToTopOnRetap(.search)
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Titles, cast and directors")
        .searchScopes($scope) {
            ForEach(SearchScope.allCases) { Text($0.rawValue).tag($0) }
        }
        .onSubmit(of: .search) { settings.rememberSearch(query) }
        .onChange(of: router.pendingSearch, initial: true) { _, text in
            guard let text else { return }
            query = text
            router.pendingSearch = nil
        }
        .task(id: "\(query)|\(attempt)") {
            let text = query
            searchError = nil
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { movies = []; series = []; isSearching = false; return }
            isSearching = true
            defer { isSearching = false }
            try? await Task.sleep(nanoseconds: 350_000_000)   // debounce typing
            guard !Task.isCancelled else { return }
            async let m = asyncResult { try await Cinemeta.search(text, kind: .movie) }
            async let s = asyncResult { try await Cinemeta.search(text, kind: .series) }
            let (foundMovies, foundSeries) = await (m, s)
            guard !Task.isCancelled else { return }
            movies = library.shown((try? foundMovies.get()) ?? [], hidingWatched: false)
            series = library.shown((try? foundSeries.get()) ?? [], hidingWatched: false)
            // Both failing is an error worth showing; one failing still shows the other's titles.
            if case let .failure(error) = foundMovies, case .failure = foundSeries {
                searchError = PlaybackError.describe(error)
            }
        }
    }

    /// Before anything is typed: recent searches, then what's popular.
    @ViewBuilder private var suggestions: some View {
        if !settings.recentSearches.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Recent Searches").font(.title3.weight(.bold))
                    Spacer()
                    Button("Clear") { withAnimation { settings.clearRecentSearches() } }
                        .font(.subheadline.weight(.semibold))
                }
                ForEach(settings.recentSearches, id: \.self) { recent in
                    HStack {
                        Button {
                            query = recent
                        } label: {
                            Label(recent, systemImage: "clock.arrow.circlepath")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button {
                            withAnimation { settings.forgetSearch(recent) }
                        } label: {
                            Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(Theme.secondaryText)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(recent)")
                    }
                    .padding(.vertical, 6)
                    Divider().opacity(0.4)
                }
            }
            .padding(.horizontal, 20)
        }
        LazyShelf(title: "Popular Movies", kind: .movie, catalog: .popular, genre: nil)
        LazyShelf(title: "Popular Series", kind: .series, catalog: .popular, genre: nil)
    }

    private func section(_ title: String, _ items: [MediaItem], _ metrics: CardMetrics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title, subtitle: "\(items.count) found").padding(.horizontal, 20)
            LazyVGrid(columns: metrics.posterColumns, spacing: 22) {
                ForEach(items) { item in
                    NavigationLink(value: item) { PosterCard(item: item, width: metrics.poster, mark: library.mark(for: item, downloads: downloads)) }
                        .buttonStyle(.plain)
                        .contextMenu { TitleContextMenu(item: item) }
                        .simultaneousGesture(TapGesture().onEnded { settings.rememberSearch(query) })
                }
            }
            .padding(.horizontal, 20)
        }
    }
}

// MARK: - People

@MainActor
final class PersonModel: ObservableObject {
    @Published var movies: [MediaItem] = []
    @Published var series: [MediaItem] = []
    @Published var directed: Set<String> = []
    @Published var isLoading = false
    @Published var error: String?
    private var loaded = ""

    func load(_ name: String) async {
        guard loaded != name else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let found = try await Cinemeta.person(name)
            guard !Task.isCancelled else { return }
            movies = found.movies
            series = found.series
            directed = found.directed
            error = nil
            loaded = name
        } catch {
            self.error = error.localizedDescription
        }
    }

    var all: [MediaItem] { movies + series }

    /// The best-rated few: what the person is known for.
    var knownFor: [MediaItem] {
        all.sorted { (Double($0.rating ?? "") ?? 0) > (Double($1.rating ?? "") ?? 0) }.prefix(10).map { $0 }
    }

    /// Everything, newest first.
    var filmography: [MediaItem] {
        all.sorted { ($0.year ?? "") > ($1.year ?? "") }
    }
}

/// A cast or crew member: what they're known for, then everything they're credited in.
struct PersonView: View {
    let name: String
    @State private var person: TMDB.Person?
    @State private var expandedBio = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 16) {
                    PersonPhoto(name: name, photo: person?.photo, size: 84)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name).font(.largeTitle.weight(.bold)).lineLimit(2).minimumScaleFactor(0.6)
                        Text(subtitle).font(.subheadline).foregroundStyle(Theme.secondaryText)
                    }
                }
                .padding(.horizontal, 20)
                if let bio = person?.biography {
                    Text(bio)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(expandedBio ? nil : 5)
                        .onTapGesture { withAnimation(.snappy) { expandedBio.toggle() } }
                        .padding(.horizontal, 20)
                        .frame(maxWidth: 760, alignment: .leading)
                }
                PersonResults(name: name)
            }
            .padding(.vertical, 12)
        }
        .background(Theme.Backdrop())
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: name) { person = await TMDB.shared.person(named: name, details: true) }
    }

    private var subtitle: String {
        var parts = [person?.department ?? "Cast and crew"]
        if let born = person?.birthday { parts.append("Born \(born)") }
        if let place = person?.birthplace { parts.append(place) }
        return parts.joined(separator: " · ")
    }
}

/// A person's photo from TMDB when there is one, otherwise their initials.
struct PersonPhoto: View {
    let name: String
    let photo: URL?
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            Circle().fill(Theme.accentGradient)
            Text(name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined())
                .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
            if let photo {
                RemoteImage(url: photo, targetWidth: size)
                    .clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Known For and Filmography for a name; used by the person page and Search's People scope.
struct PersonResults: View {
    let name: String
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: DownloadStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.cardScale) private var cardScale
    @StateObject private var model = PersonModel()

    var body: some View {
        let metrics = CardMetrics(sizeClass, scale: cardScale)
        VStack(alignment: .leading, spacing: 26) {
            if model.isLoading && model.all.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
            } else if let error = model.error, model.all.isEmpty {
                StateMessage(title: "Couldn't search", message: error, actionTitle: "Retry") {
                    Task { await model.load(name) }
                }
            } else if model.all.isEmpty {
                StateMessage(title: "No credits found", message: "Cinemeta lists nothing for “\(name)”.", systemImage: "person.crop.circle.badge.questionmark")
                    .padding(.top, 40)
            } else {
                HStack(spacing: 8) {
                    StatusPill(text: "\(model.movies.count) movies", systemImage: "film")
                    StatusPill(text: "\(model.series.count) series", systemImage: "tv")
                    if !model.directed.isEmpty {
                        StatusPill(text: "Directed \(model.directed.count)", systemImage: "megaphone", tint: Theme.accent)
                    }
                }
                .padding(.horizontal, 20)
                ShelfRow(title: "Known For", items: model.knownFor) { item in
                    NavigationLink(value: item) { PosterCard(item: item, width: metrics.poster, mark: library.mark(for: item, downloads: downloads)) }
                        .buttonStyle(.plain)
                        .contextMenu { TitleContextMenu(item: item) }
                }
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Filmography", subtitle: "Newest first").padding(.horizontal, 20)
                    LazyVStack(spacing: 10) {
                        ForEach(model.filmography) { item in
                            NavigationLink(value: item) {
                                MediaRow(item: item) {
                                    if model.directed.contains(item.id) {
                                        StatusPill(text: "Director", tint: Theme.accent)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .contextMenu { TitleContextMenu(item: item) }
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
        .task(id: name) {
            try? await Task.sleep(nanoseconds: 300_000_000)  // debounce typing in Search
            guard !Task.isCancelled else { return }
            await model.load(name)
        }
    }
}
