import SwiftUI

/// How My List is drawn.
enum LibraryDisplay: String, CaseIterable, Identifiable {
    case posters, rows, banners, overview
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var systemImage: String {
        switch self {
        case .posters: return "square.grid.3x3"
        case .rows: return "list.bullet"
        case .banners: return "rectangle.grid.1x2"
        case .overview: return "chart.bar.xaxis"
        }
    }
}

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, movies, series, unwatched
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All"
        case .movies: return "Movies"
        case .series: return "Series"
        case .unwatched: return "Not Watched"
        }
    }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case added, title, year, rating
    var id: String { rawValue }
    var title: String {
        switch self {
        case .added: return "Recently Added"
        case .title: return "Title"
        case .year: return "Year"
        case .rating: return "Rating"
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var playback: PlaybackCenter
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var upcoming: UpcomingStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.cardScale) private var cardScale
    @AppStorage("library.display") private var display: LibraryDisplay = .posters
    @AppStorage("library.filter") private var filter: LibraryFilter = .all
    @AppStorage("library.sort") private var sort: LibrarySort = .added

    private var shown: [MediaItem] {
        let filtered = library.watchlist.filter { item in
            switch filter {
            case .all: return true
            case .movies: return item.kind == .movie
            case .series: return item.kind == .series
            case .unwatched: return item.kind == .series || !library.isWatched(PlaybackTarget(item: item))
            }
        }
        switch sort {
        case .added: return filtered
        case .title: return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .year: return filtered.sorted { ($0.year ?? "") > ($1.year ?? "") }
        case .rating: return filtered.sorted { (Double($0.rating ?? "") ?? 0) > (Double($1.rating ?? "") ?? 0) }
        }
    }

    var body: some View {
        let metrics = CardMetrics(sizeClass, scale: cardScale)
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                quickLinks
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
                myList(metrics)
            }
            .padding(.vertical, 12)
        }
        .background(Theme.Backdrop())
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { router.openSettings() } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
            }
        }
    }

    // MARK: Quick links

    private var quickLinks: some View {
        let failed = !downloads.problems.isEmpty
        let downloadDetail: String = {
            if !downloads.active.isEmpty { return "\(downloads.active.count) downloading" }
            if failed { return "\(downloads.problems.count) failed" }
            return downloads.items.isEmpty ? "None yet" : "\(downloads.finished.count) saved"
        }()
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            NavigationLink(value: LibraryPage.downloads) {
                linkTile("Downloads", detail: downloadDetail, systemImage: "arrow.down.circle.fill", dot: failed)
            }
            NavigationLink(value: LibraryPage.history) {
                linkTile("History", detail: library.history.isEmpty ? "Nothing yet" : "\(library.history.count) watched", systemImage: "clock.fill")
            }
            Button { router.tab = .calendar } label: {
                let next = upcoming.upcoming.first
                linkTile("Calendar", detail: next.map { "Next: \($0.item.name)" } ?? "Upcoming episodes", systemImage: "calendar")
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
    }

    private func linkTile(_ title: String, detail: String, systemImage: String, dot: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).font(.title3).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title).font(.subheadline.weight(.semibold))
                    if dot { AttentionDot(size: 7) }
                }
                Text(detail).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
        .contentShape(Rectangle())
    }

    // MARK: My List

    @ViewBuilder private func myList(_ metrics: CardMetrics) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("My List").font(.title3.weight(.bold))
                Text("\(library.watchlist.count)").font(.subheadline).foregroundStyle(Theme.secondaryText)
                Spacer()
                if display != .overview {
                    Menu {
                        Picker("Show", selection: $filter) {
                            ForEach(LibraryFilter.allCases) { Text($0.title).tag($0) }
                        }
                        Picker("Sort", selection: $sort) {
                            ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
                        }
                    } label: {
                        Label(filter == .all ? "Filter" : filter.title, systemImage: "line.3.horizontal.decrease.circle")
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
            .padding(.horizontal, 20)

            Picker("Display", selection: $display.animation(.snappy)) {
                ForEach(LibraryDisplay.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 460)
            .padding(.horizontal, 20)

            if library.watchlist.isEmpty && display != .overview {
                StateMessage(title: "Nothing in My List",
                             message: "Tap + on any title to keep it here. Its new episodes appear on Calendar.",
                             systemImage: "bookmark", actionTitle: "Explore") { router.tab = .explore }
                    .padding(.top, 20)
            } else if shown.isEmpty && display != .overview {
                StateMessage(title: "Nothing matches", message: "No titles in My List match “\(filter.title)”.",
                             systemImage: "line.3.horizontal.decrease.circle", actionTitle: "Show All") { filter = .all }
            } else {
                switch display {
                case .posters:
                    LazyVGrid(columns: metrics.posterColumns, spacing: 22) {
                        ForEach(shown) { item in
                            NavigationLink(value: item) { PosterCard(item: item, width: metrics.poster, mark: posterMark(item)) }
                                .buttonStyle(.plain)
                                .contextMenu { TitleContextMenu(item: item) }
                        }
                    }
                    .padding(.horizontal, 20)
                case .rows:
                    LazyVStack(spacing: 10) {
                        ForEach(shown) { item in
                            NavigationLink(value: item) {
                                MediaRow(item: item) { rowStatus(item) }
                            }
                            .buttonStyle(.plain)
                            .contextMenu { TitleContextMenu(item: item) }
                        }
                    }
                    .padding(.horizontal, 20)
                case .banners:
                    LazyVGrid(columns: metrics.landscapeColumns, spacing: 16) {
                        ForEach(shown) { item in
                            NavigationLink(value: item) {
                                BannerCard(item: item, width: metrics.landscape * 1.15, eyebrow: bannerEyebrow(item),
                                           subtitle: HeroCarousel.subtitle(for: item), fraction: movieProgress(item))
                            }
                            .buttonStyle(.plain)
                            .contextMenu { TitleContextMenu(item: item) }
                        }
                    }
                    .padding(.horizontal, 20)
                case .overview:
                    LibraryOverview()
                        .padding(.horizontal, 20)
                }
            }
        }
    }

    /// Inside My List every title is listed, so the mark says something more useful than that.
    private func posterMark(_ item: MediaItem) -> PosterCard.PosterMark? {
        let mark = library.mark(for: item, downloads: downloads)
        if case .listed? = mark { return nil }
        return mark
    }

    private func movieProgress(_ item: MediaItem) -> Double? {
        guard item.kind == .movie, let entry = library.progress(for: PlaybackTarget(item: item)),
              entry.position >= Library.minimumResume, !entry.isFinished else { return nil }
        return entry.fraction
    }

    private func bannerEyebrow(_ item: MediaItem) -> String? {
        if item.kind == .series, let next = upcoming.upcoming.first(where: { $0.item.id == item.id }) {
            return "\(next.episode.code) · \(next.date.formatted(.relative(presentation: .named)))"
        }
        if item.kind == .movie, library.isWatched(PlaybackTarget(item: item)) { return "Watched" }
        return item.kind.singular
    }

    @ViewBuilder private func rowStatus(_ item: MediaItem) -> some View {
        let target = PlaybackTarget(item: item)
        if item.kind == .movie, library.isWatched(target) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.cached).accessibilityLabel("Watched")
        } else if item.kind == .movie, downloads.item(for: target)?.isFinished == true {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accent).accessibilityLabel("Downloaded")
        } else if item.kind == .series, let next = upcoming.upcoming.first(where: { $0.item.id == item.id }) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(next.episode.code).font(.caption.weight(.bold))
                Text(next.date.formatted(.dateTime.month(.abbreviated).day())).font(.caption2).foregroundStyle(Theme.secondaryText)
            }
        } else {
            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Theme.secondaryText)
        }
    }
}

/// Library's Overview: what's in My List and what you've watched, as numbers and bars.
struct LibraryOverview: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var upcoming: UpcomingStore

    private var watchedCount: Int { library.history.filter(\.isFinished).count }
    private var hoursWatched: Double { library.history.reduce(0) { $0 + min($1.position, $1.duration) } / 3600 }
    private var thisWeek: Int {
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        return library.history.filter { $0.updatedAt > cutoff }.count
    }

    private var genres: [(String, Int)] {
        var counts: [String: Int] = [:]
        for item in library.watchlist + library.history.map(\.item) {
            for genre in item.genres.prefix(2) { counts[genre, default: 0] += 1 }
        }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(6).map { ($0.key, $0.value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                tile("\(library.watchlist.filter { $0.kind == .movie }.count)", "Movies listed", "film")
                tile("\(library.watchlist.filter { $0.kind == .series }.count)", "Series listed", "tv")
                tile("\(watchedCount)", "Finished", "checkmark.circle")
                tile(hoursWatched >= 10 ? "\(Int(hoursWatched))" : String(format: "%.1f", hoursWatched), "Hours watched", "clock")
                tile("\(thisWeek)", "Played this week", "calendar")
                tile("\(upcoming.upcoming.count)", "Episodes coming", "calendar.badge.clock")
                tile("\(downloads.finished.count)", "Downloads", "arrow.down.circle")
                tile(ByteCountFormatter.string(fromByteCount: downloads.usedBytes, countStyle: .file), "Saved on device", "internaldrive")
            }
            if !genres.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Your Genres").font(.headline)
                    let top = Double(genres.first?.1 ?? 1)
                    ForEach(genres, id: \.0) { entry in
                        let (genre, count) = entry
                        HStack(spacing: 10) {
                            Text(genre).font(.subheadline).frame(width: 110, alignment: .leading).lineLimit(1)
                            GeometryReader { proxy in
                                Capsule().fill(Theme.surface)
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(Theme.accentGradient).frame(width: max(8, proxy.size.width * Double(count) / top))
                                    }
                            }
                            .frame(height: 10)
                            Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(Theme.secondaryText).frame(width: 28, alignment: .trailing)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }

    private func tile(_ value: String, _ label: String, _ systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: systemImage).font(.subheadline).foregroundStyle(Theme.accent)
            Text(value).font(.title2.weight(.bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
