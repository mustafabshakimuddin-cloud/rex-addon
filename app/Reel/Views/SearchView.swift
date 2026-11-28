import SwiftUI

// MARK: - Search

struct SearchView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppRouter.self) private var router
    @Environment(Library.self) private var library
    @Environment(DownloadStore.self) private var downloads
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
                #if os(tvOS)
                // Apple TV's search field has no scope bar.
                Picker("Search in", selection: $scope) {
                    ForEach(SearchScope.allCases) { Text($0.rawValue.localized).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, DeviceStyle.gutter)
                #endif
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
                        .cardButton()
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
                            .cardButton()
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
        #if os(iOS)
        .searchScopes($scope) {
            ForEach(SearchScope.allCases) { Text($0.rawValue.localized).tag($0) }
        }
        #endif
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
                        .cardButton()
                        Button {
                            withAnimation { settings.forgetSearch(recent) }
                        } label: {
                            Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(Theme.secondaryText)
                        }
                        .cardButton()
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
                        .cardButton()
                        .contextMenu { TitleContextMenu(item: item) }
                        .simultaneousGesture(TapGesture().onEnded { settings.rememberSearch(query) })
                }
            }
            .padding(.horizontal, 20)
        }
    }
}
