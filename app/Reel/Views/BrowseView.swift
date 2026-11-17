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
        key = "\(kind.rawValue)|\(catalog.rawValue)|\(genre ?? "")"
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
            if items.isEmpty { self.error = error.localizedDescription }
        }
    }
}

struct BrowseView: View {
    let kind: MediaKind
    @Environment(\.horizontalSizeClass) private var sizeClass
    @StateObject private var model = BrowseModel()
    @State private var catalog: Cinemeta.Catalog = .popular
    @State private var genre: String?

    var body: some View {
        let metrics = CardMetrics(sizeClass)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("List", selection: $catalog) {
                    ForEach(Cinemeta.Catalog.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                .padding(.horizontal, 20)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        genreButton(nil, title: "All")
                        ForEach(Cinemeta.genres, id: \.self) { genreButton($0, title: $0) }
                    }
                    .padding(.horizontal, 20)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: metrics.poster, maximum: metrics.poster * 1.35), spacing: 14, alignment: .top)], spacing: 22) {
                    ForEach(model.items) { item in
                        NavigationLink(value: item) {
                            PosterCard(item: item, width: metrics.poster)
                        }
                        .buttonStyle(.plain)
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
                } else if let error = model.error {
                    StateMessage(title: "Couldn't load", message: error, actionTitle: "Retry") {
                        Task { await model.reset(kind: kind, catalog: catalog, genre: genre) }
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .background(Theme.Backdrop())
        .navigationTitle(kind.title)
        .navigationDestination(for: MediaItem.self) { DetailView(item: $0) }
        .task(id: "\(catalog.rawValue)|\(genre ?? "")") {
            await model.reset(kind: kind, catalog: catalog, genre: genre)
        }
    }

    private func genreButton(_ value: String?, title: String) -> some View {
        Button {
            withAnimation(.snappy) { genre = value }
        } label: {
            Text(title).font(.subheadline.weight(.semibold)).padding(.horizontal, 6)
        }
        .buttonStyle(.glass)
        .tint(genre == value ? Theme.accent : nil)
    }
}

struct SearchView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var query = ""
    @State private var movies: [MediaItem] = []
    @State private var series: [MediaItem] = []
    @State private var isSearching = false
    @State private var scope: SearchScope = .all

    enum SearchScope: String, CaseIterable, Identifiable {
        case all = "All", movies = "Movies", series = "Series"
        var id: String { rawValue }
    }

    var body: some View {
        let metrics = CardMetrics(sizeClass)
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    StateMessage(title: "Search", message: "Find movies and series by title.", systemImage: "magnifyingglass")
                        .padding(.top, 60)
                } else if !isSearching && movies.isEmpty && series.isEmpty {
                    StateMessage(title: "No results", message: "Nothing matches “\(query)”.", systemImage: "magnifyingglass")
                        .padding(.top, 60)
                }
                if scope != .series, !movies.isEmpty { section("Movies", movies, metrics) }
                if scope != .movies, !series.isEmpty { section("Series", series, metrics) }
            }
            .padding(.vertical, 12)
        }
        .background(Theme.Backdrop())
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Movies and series")
        .searchScopes($scope) {
            ForEach(SearchScope.allCases) { Text($0.rawValue).tag($0) }
        }
        .navigationDestination(for: MediaItem.self) { DetailView(item: $0) }
        .task(id: query) {
            let text = query
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { movies = []; series = []; return }
            try? await Task.sleep(nanoseconds: 350_000_000)   // debounce typing
            guard !Task.isCancelled else { return }
            isSearching = true
            async let m = try? Cinemeta.search(text, kind: .movie)
            async let s = try? Cinemeta.search(text, kind: .series)
            let (foundMovies, foundSeries) = await (m ?? [], s ?? [])
            guard !Task.isCancelled else { return }
            movies = foundMovies
            series = foundSeries
            isSearching = false
        }
    }

    private func section(_ title: String, _ items: [MediaItem], _ metrics: CardMetrics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.weight(.bold)).padding(.horizontal, 20)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: metrics.poster, maximum: metrics.poster * 1.35), spacing: 14, alignment: .top)], spacing: 22) {
                ForEach(items) { item in
                    NavigationLink(value: item) { PosterCard(item: item, width: metrics.poster) }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
    }
}
