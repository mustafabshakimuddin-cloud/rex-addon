import SwiftUI

@MainActor
@Observable
final class BrowseModel {
    var items: [MediaItem] = []
    var isLoading = false
    var error: String?
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
    @Environment(AppRouter.self) private var router
    @Environment(AppSettings.self) private var settings
    @AppStorage("explore.layout") private var layout: ExploreLayout = .rows

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Picker("Type", selection: Bindable(router).exploreKind) {
                    ForEach(MediaKind.allCases) { Text($0.title.localized).tag($0) }
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
                    Toggle(isOn: Bindable(settings).hideWatched) { Label("Hide Watched Films", systemImage: "eye.slash") }
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

    @Environment(AppSettings.self) private var settings

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
    @Environment(Library.self) private var library
    @Environment(DownloadStore.self) private var downloads
    @Environment(AppSettings.self) private var settings
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
    @Environment(Library.self) private var library
    @Environment(DownloadStore.self) private var downloads
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
    @Environment(Library.self) private var library
    @Environment(DownloadStore.self) private var downloads
    @Environment(AppSettings.self) private var settings
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
                .prefetchPosters(items, width: metrics.poster)
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
                ForEach(Cinemeta.Catalog.allCases) { Text($0.title.localized).tag($0) }
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
                ForEach(GridOrder.allCases) { Text($0.title.localized).tag($0) }
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
            Text(title.localized).font(.subheadline.weight(.semibold)).padding(.horizontal, 6)
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
    @Environment(Library.self) private var library
    @Environment(DownloadStore.self) private var downloads
    @Environment(AppSettings.self) private var settings
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.cardScale) private var cardScale
    @State private var model = BrowseModel()

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
