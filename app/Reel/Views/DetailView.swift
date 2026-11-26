import SwiftUI

@MainActor
@Observable
final class DetailModel {
    var detail: MediaDetail?
    var error: String?
    var season: Int = 1

    var isLoading = false

    func load(_ item: MediaItem, library: Library, force: Bool = false) async {
        guard detail == nil || force, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded: MediaDetail
            do {
                loaded = try await Cinemeta.detail(item.kind, id: item.id)
            } catch HTTPError.status(404, _) where item.name.isEmpty {
                // A bare link doesn't say whether it is a film or a series: try the other.
                loaded = try await Cinemeta.detail(item.kind == .movie ? .series : .movie, id: item.id)
            }
            detail = loaded
            error = nil
            library.learnEpisodes(loaded)
            let caughtUp = library.caughtUp(in: loaded)
            season = library.nextEpisode(in: loaded)?.season ?? caughtUp.nextAiring?.season
                ?? (caughtUp.caughtUp ? loaded.seasons.filter { $0 > 0 }.last : nil) ?? loaded.seasons.first ?? 1
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct DetailView: View {
    let item: MediaItem
    @Environment(Library.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(PlaybackCenter.self) private var playback
    @Environment(DownloadStore.self) private var downloads
    @Environment(UpcomingStore.self) private var upcoming
    @Environment(TraktStore.self) private var trakt
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.openURL) private var openURL
    @State private var model = DetailModel()
    @State private var width: CGFloat = 390
    @State private var height: CGFloat = 844
    @State private var expandedOverview = false

    private var shown: MediaItem { model.detail?.item ?? item }
    private var wide: Bool { width >= 700 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                VStack(alignment: .leading, spacing: 26) {
                    libraryState
                    overview
                    if let detail = model.detail, shown.kind == .series, !detail.episodes.isEmpty {
                        episodesSection(detail)
                    }
                    if let detail = model.detail, !detail.cast.isEmpty || !detail.directors.isEmpty { castSection(detail) }
                    if let error = model.error, model.detail == nil {
                        StateMessage(title: "Couldn't load details", message: error, actionTitle: model.isLoading ? nil : "Retry") {
                            Task { await model.load(item, library: library, force: true) }
                        }
                    }
                }
                .padding(.horizontal, wide ? 48 : 20)
                .readableWidth(1100)
                MoreLikeThis(item: shown)
                    .readableWidth(1100 + (wide ? 96 : 40))
            }
            .padding(.bottom, 50)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { width = $0.width; height = $0.height }
        .ignoresSafeArea(edges: .top)
        .background(Theme.Backdrop())
        .navigationTitle(shown.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    library.toggleWatchlist(shown)
                } label: {
                    Image(systemName: library.isInWatchlist(shown) ? "checkmark" : "plus")
                }
                .accessibilityLabel(library.isInWatchlist(shown) ? "Remove from My List" : "Add to My List")
            }
            ToolbarItem(placement: .topBarTrailing) { moreMenu }
        }
        .task {
            await model.load(item, library: library)
            if let target = primaryTarget { playback.prefetch(target, settings: settings) }
        }
        .onDisappear { if let target = primaryTarget { playback.cancelPrefetch(target) } }
        .userActivity(TitleActivity.type) { activity in
            activity.title = shown.name
            activity.userInfo = ["id": shown.id, "kind": shown.kind.rawValue]
            activity.isEligibleForHandoff = true
            activity.isEligibleForSearch = true
            activity.webpageURL = URL(string: "https://www.imdb.com/title/\(shown.id)/")
        }
    }

    // MARK: Header

    private var headerHeight: CGFloat {
        let natural = wide ? min(max(width * 0.42, 380), 560) : min(width * 1.05, 520)
        // The Duo's outer display is short; leave room to see the overview below the header.
        return min(natural, height * 0.62)
    }

    /// A fixed-height box that takes exactly the width it is offered. The picture and gradients are
    /// its background, so nothing in them can widen the page: an image in fill mode reports its
    /// natural width, and the extension effect reaches into the safe area, and either one inside a
    /// ZStack widened the whole scroll view and pushed the page off the left edge.
    private var header: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: headerHeight)
            .background {
                RemoteImage(url: shown.background ?? shown.poster, targetWidth: width * 0.75)
                    .clipped()
                    // On iPhone Duo's outer display (and beside a side bar) the picture continues
                    // under the status column instead of stopping short of the edge.
                    .backgroundExtensionEffect()
            }
            .overlay {
                ZStack {
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0.25),
                        .init(color: Theme.background.opacity(0.75), location: 0.7),
                        .init(color: Theme.background, location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                    if wide {
                        LinearGradient(colors: [Theme.background.opacity(0.85), .clear], startPoint: .leading, endPoint: .center)
                    }
                }
                .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 14) {
                    TitleLogo(item: shown, maxHeight: wide ? 120 : 90)
                        .frame(maxWidth: wide ? 460 : 300, alignment: .leading)
                    metaLine
                    actionButtons
                }
                .padding(.horizontal, wide ? 48 : 20)
                .padding(.bottom, 8)
                .frame(maxWidth: 1100, alignment: .leading)
            }
    }

    private var metaLine: some View {
        let parts: [String] = [shown.year, model.detail?.runtime].compactMap { $0 } + shown.genres.prefix(3)
        return HStack(spacing: 10) {
            if let rating = shown.rating {
                Label(rating, systemImage: "star.fill").foregroundStyle(.yellow)
            }
            Text(parts.joined(separator: " · ")).foregroundStyle(Theme.secondaryText)
        }
        .font(.subheadline.weight(.medium))
        .lineLimit(1)
    }

    private var primaryTarget: PlaybackTarget? {
        if shown.kind == .movie { return PlaybackTarget(item: shown) }
        guard let detail = model.detail, let episode = library.nextEpisode(in: detail) else { return nil }
        return PlaybackTarget(item: shown, episode: episode)
    }

    /// For a series you're up to date with: the first episode, to watch it again.
    private var rewatchTarget: PlaybackTarget? {
        guard shown.kind == .series, let detail = model.detail, library.caughtUp(in: detail).caughtUp,
              let first = detail.episodes.filter({ $0.season > 0 && $0.hasAired }).min(by: { ($0.season, $0.number) < ($1.season, $1.number) })
        else { return nil }
        return PlaybackTarget(item: shown, episode: first)
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            if let target = primaryTarget {
                let resume = library.resumePosition(for: target)
                Button {
                    playback.play(target, settings: settings, library: library)
                } label: {
                    Label(playTitle(target, resume: resume), systemImage: "play.fill")
                        .font(.headline).padding(.horizontal, 10).lineLimit(1)
                }
                .buttonStyle(.glassProminent)
                .contextMenu {
                    if resume != nil {
                        Button { playback.play(target, settings: settings, library: library, fromStart: true) } label: {
                            Label("Play from Beginning", systemImage: "backward.end.fill")
                        }
                    }
                }

                // With automatic play on, Play skips the list; this is the way back to it.
                if settings.autoPlayBest {
                    Button {
                        playback.chooseSource(for: target)
                    } label: {
                        Label("Sources", systemImage: "list.bullet.rectangle").font(.headline)
                    }
                    .buttonStyle(.glass)
                }
            } else if let rewatch = rewatchTarget {
                Button {
                    playback.play(rewatch, settings: settings, library: library, fromStart: true)
                } label: {
                    Label("Watch Again", systemImage: "arrow.counterclockwise").font(.headline).padding(.horizontal, 10).lineLimit(1)
                }
                .buttonStyle(.glassProminent)
            } else if shown.kind == .series && model.detail == nil && model.error == nil {
                ProgressView()
            }
            if let target = primaryTarget, shown.kind == .movie {
                downloadButton(target)
            }
            if let trailer = model.detail?.trailerYouTubeID, let url = URL(string: "https://www.youtube.com/watch?v=\(trailer)") {
                Button { openURL(url) } label: { Image(systemName: "film.stack").font(.headline) }
                    .buttonStyle(.glass)
                    .accessibilityLabel("Trailer")
            }
        }
    }

    @ViewBuilder private func downloadButton(_ target: PlaybackTarget) -> some View {
        let item = downloads.item(for: target)
        Button {
            if item == nil { playback.download(target, settings: settings) }
        } label: {
            switch item?.state {
            case .finished?: Image(systemName: "arrow.down.circle.fill").font(.headline)
            case .downloading?:
                ProgressView(value: item?.fraction ?? 0)
                    .progressViewStyle(.circular)
                    .frame(width: 20, height: 20)
            default: Image(systemName: "arrow.down.circle").font(.headline)
            }
        }
        .buttonStyle(.glass)
        .accessibilityLabel(item?.isFinished == true ? "Downloaded" : "Download")
    }

    private func playTitle(_ target: PlaybackTarget, resume: Double?) -> String {
        let verb = resume == nil ? "Play" : "Resume"
        guard let episode = target.episode else { return verb }
        return "\(verb) \(episode.code)"
    }

    static func ratingWord(_ value: Int) -> String {
        ["", "Weak sauce", "Terrible", "Bad", "Poor", "Meh", "Fair", "Good", "Great", "Superb", "Totally ninja!"][value]
    }

    /// Share, IMDb and watched state: what the toolbar's "…" holds.
    private var moreMenu: some View {
        Menu {
            if shown.kind == .movie {
                let target = PlaybackTarget(item: shown)
                if library.isWatched(target) {
                    Button { library.markUnwatched(target) } label: { Label("Mark as Unwatched", systemImage: "circle") }
                } else {
                    Button { library.markWatched(target) } label: { Label("Mark as Watched", systemImage: "checkmark.circle") }
                }
                Button { playback.chooseSource(for: target) } label: { Label("Choose Source", systemImage: "list.bullet.rectangle") }
            } else if let detail = model.detail {
                let aired = detail.episodes.filter { $0.season > 0 && $0.hasAired }
                Button { library.markWatched(aired, of: shown) } label: { Label("Mark All Aired as Watched", systemImage: "checkmark.circle") }
                Button { library.markUnwatched(detail.episodes, of: shown) } label: { Label("Mark All as Unwatched", systemImage: "circle") }
            }
            AddToListMenu(item: shown)
            if trakt.isConnected {
                Menu {
                    ForEach((1...10).reversed(), id: \.self) { value in
                        Button("\(value) – \(Self.ratingWord(value))") { trakt.rate(shown, rating: value) }
                    }
                    Divider()
                    Button("Remove Rating", role: .destructive) { trakt.rate(shown, rating: 0) }
                } label: {
                    Label("Rate on Trakt", systemImage: "star")
                }
            }
            Divider()
            if let imdb = URL(string: "https://www.imdb.com/title/\(shown.id)/") {
                ShareLink(item: imdb, subject: Text(shown.name)) { Label("Share", systemImage: "square.and.arrow.up") }
                Link(destination: imdb) { Label("Open in IMDb", systemImage: "arrow.up.right.square") }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("More")
    }

    /// Where this title stands in your library, at a glance.
    @ViewBuilder private var libraryState: some View {
        let pills = statePills
        if !pills.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(pills, id: \.text) { pill in pill }
                }
            }
            .scrollClipDisabled()
        }
    }

    private var statePills: [StatusPill] {
        var pills: [StatusPill] = []
        if library.isInWatchlist(shown) { pills.append(StatusPill(text: "In My List", systemImage: "bookmark.fill")) }
        if shown.kind == .movie {
            let target = PlaybackTarget(item: shown)
            if library.isWatched(target) {
                pills.append(StatusPill(text: "Watched", systemImage: "checkmark.circle.fill", tint: Theme.cached))
            } else if let entry = library.progress(for: target), entry.position >= Library.minimumResume {
                pills.append(StatusPill(text: "\(Int(entry.fraction * 100))% watched", systemImage: "play.circle", tint: Theme.accent))
            }
            if downloads.item(for: target)?.isFinished == true {
                pills.append(StatusPill(text: "Downloaded", systemImage: "arrow.down.circle.fill", tint: Theme.accent))
            }
        } else if let detail = model.detail {
            let regular = detail.episodes.filter { $0.season > 0 && $0.hasAired }
            let watched = regular.filter { library.isWatched($0) }.count
            if watched > 0 {
                pills.append(StatusPill(text: "\(watched) of \(regular.count) watched", systemImage: "checkmark.circle",
                                        tint: watched == regular.count ? Theme.cached : .white))
            }
            let saved = detail.episodes.filter { downloads.item(for: PlaybackTarget(item: shown, episode: $0))?.isFinished == true }.count
            if saved > 0 { pills.append(StatusPill(text: "\(saved) downloaded", systemImage: "arrow.down.circle.fill", tint: Theme.accent)) }
            let caughtUp = library.caughtUp(in: detail).caughtUp
            if caughtUp { pills.append(StatusPill(text: "Caught up", systemImage: "checkmark.seal.fill", tint: Theme.cached)) }
            if let next = detail.episodes.filter({ !$0.hasAired && $0.season > 0 }).min(by: { ($0.released ?? .distantFuture) < ($1.released ?? .distantFuture) }),
               let date = next.released {
                pills.append(StatusPill(text: "\(next.code) \(date.formatted(.relative(presentation: .named)))", systemImage: "calendar", tint: Theme.accent))
            }
        }
        return pills
    }

    // MARK: Body sections

    private var overview: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let text = shown.overview, !text.isEmpty {
                Text(text)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.86))
                    .lineLimit(expandedOverview ? nil : 4)
                    .onTapGesture { withAnimation(.snappy) { expandedOverview.toggle() } }
            }
            if let directors = model.detail?.directors, !directors.isEmpty {
                Text("Directed by \(directors.joined(separator: ", "))").font(.footnote).foregroundStyle(Theme.secondaryText)
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    private func episodesSection(_ detail: MediaDetail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Episodes").font(.title3.weight(.bold))
                Spacer()
                Menu {
                    ForEach(detail.seasons, id: \.self) { season in
                        Button(season == 0 ? "Specials" : "Season \(season)") { model.season = season }
                    }
                    Divider()
                    let episodes = detail.episodes(in: model.season)
                    let toSave = episodes.filter { $0.hasAired && downloads.item(for: PlaybackTarget(item: shown, episode: $0)) == nil }
                    if !toSave.isEmpty {
                        Button { playback.download(toSave, of: shown, settings: settings) } label: {
                            Label("Download Season (\(toSave.count))", systemImage: "arrow.down.circle")
                        }
                    }
                    if let next = library.nextEpisode(in: detail) {
                        let following = detail.episodes.filter { $0.season > 0 && $0.hasAired }
                            .sorted { ($0.season, $0.number) < ($1.season, $1.number) }
                            .drop { $0.id != next.id }.prefix(3)
                        Button { playback.download(Array(following), of: shown, settings: settings) } label: {
                            Label("Download Next \(following.count) Episodes", systemImage: "arrow.down.to.line.circle")
                        }
                    }
                    if episodes.filter(\.hasAired).allSatisfy({ library.isWatched($0) }) {
                        Button { library.markUnwatched(episodes, of: shown) } label: { Label("Mark Season as Unwatched", systemImage: "circle") }
                    } else {
                        Button { library.markWatched(episodes, of: shown) } label: { Label("Mark Season as Watched", systemImage: "checkmark.circle") }
                    }
                } label: {
                    Label(model.season == 0 ? "Specials" : "Season \(model.season)", systemImage: "chevron.up.chevron.down")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.glass)
            }
            LazyVGrid(columns: wide ? [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)] : [GridItem(.flexible())], spacing: 14) {
                ForEach(detail.episodes(in: model.season)) { episode in
                    let target = PlaybackTarget(item: shown, episode: episode)
                    EpisodeRow(episode: episode, progress: library.progress(for: target),
                               watchedElsewhere: library.isWatched(episode),
                               downloaded: downloads.item(for: target)?.isFinished == true) {
                        playback.play(target, settings: settings, library: library)
                    } chooseSource: {
                        playback.chooseSource(for: target)
                    } download: {
                        playback.download(target, settings: settings)
                    } toggleWatched: {
                        if library.isWatched(episode) { library.markUnwatched(target) } else { library.markWatched(target) }
                    }
                }
            }
        }
    }

    /// Cast and directors; each opens that person's page.
    private func castSection(_ detail: MediaDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cast & Crew").font(.title3.weight(.bold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(detail.directors, id: \.self) { name in
                        NavigationLink(value: PersonRoute(name: name)) {
                            Chip(text: name, systemImage: "megaphone.fill", tint: Theme.accent)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Director")
                    }
                    ForEach(detail.cast, id: \.self) { name in
                        NavigationLink(value: PersonRoute(name: name)) {
                            if TMDB.isConfigured {
                                CastCard(name: name)
                            } else {
                                Chip(text: name, systemImage: "person.fill")
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollClipDisabled()
        }
    }
}

struct EpisodeRow: View {
    let episode: Episode
    let progress: PlaybackProgress?
    var watchedElsewhere = false
    var downloaded = false
    let play: () -> Void
    let chooseSource: () -> Void
    var download: () -> Void = {}
    var toggleWatched: () -> Void = {}

    var body: some View {
        Button(action: play) {
            HStack(alignment: .top, spacing: 14) {
                ZStack(alignment: .bottom) {
                    RemoteImage(url: episode.thumbnail, targetWidth: 110)
                        .frame(width: 150, height: 150 * 9 / 16)
                    if let progress, !progress.isFinished {
                        GeometryReader { proxy in
                            Capsule().fill(.white.opacity(0.3)).frame(height: 3)
                                .overlay(alignment: .leading) {
                                    Capsule().fill(Theme.accent).frame(width: proxy.size.width * progress.fraction, height: 3)
                                }
                                .frame(maxHeight: .infinity, alignment: .bottom)
                        }
                        .padding(6)
                    }
                    Image(systemName: progress?.isFinished == true || (progress == nil && watchedElsewhere) ? "checkmark.circle.fill" : "play.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.35))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(width: 150, height: 150 * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .opacity(episode.hasAired ? 1 : 0.45)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("\(episode.number). \(episode.title)").font(.subheadline.weight(.semibold)).lineLimit(2)
                        if downloaded {
                            Image(systemName: "arrow.down.circle.fill").font(.caption).foregroundStyle(Theme.accent)
                                .accessibilityLabel("Downloaded")
                        }
                    }
                    if let released = episode.released {
                        Text(episode.hasAired ? released.formatted(date: .abbreviated, time: .omitted) : "Airs \(released.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                    if let overview = episode.overview {
                        Text(overview).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!episode.hasAired)
        .contextMenu {
            Button(action: play) { Label("Play", systemImage: "play.fill") }
            Button(action: chooseSource) { Label("Choose Source", systemImage: "list.bullet.rectangle") }
            if !downloaded {
                Button(action: download) { Label("Download", systemImage: "arrow.down.circle") }
            }
            if episode.hasAired {
                let watched = progress?.isFinished == true || (progress == nil && watchedElsewhere)
                Button(action: toggleWatched) {
                    Label(watched ? "Mark as Unwatched" : "Mark as Watched", systemImage: watched ? "circle" : "checkmark.circle")
                }
            }
        }
    }
}

/// Popular titles that share this one's main genre.
struct MoreLikeThis: View {
    let item: MediaItem
    @Environment(Library.self) private var library
    @Environment(TraktStore.self) private var trakt
    @State private var fromTrakt = false
    @Environment(DownloadStore.self) private var downloads
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.cardScale) private var cardScale
    @State private var items: [MediaItem] = []

    var body: some View {
        let metrics = CardMetrics(sizeClass, scale: cardScale)
        Group {
            if !items.isEmpty, let genre = item.genres.first {
                ShelfRow(title: "More Like This", subtitle: fromTrakt ? "Watched alongside it on Trakt" : "Popular in \(genre)", items: items, seeAll: {
                    CatalogGridView(title: "\(genre) \(item.kind.title)", kind: item.kind, catalog: .popular, genre: genre)
                }) { other in
                    NavigationLink(value: other) { PosterCard(item: other, width: metrics.poster, mark: library.mark(for: other, downloads: downloads)) }
                        .buttonStyle(.plain)
                        .contextMenu { TitleContextMenu(item: other) }
                }
            }
        }
        .task(id: item.id + (item.genres.first ?? "")) {
            // Trakt's "related" knows what people actually watch next; the genre list is the fallback.
            if trakt.credentials != nil, let related = try? await trakt.related(item), related.count >= 4 {
                items = related.filter { $0.id != item.id }
                fromTrakt = true
                return
            }
            fromTrakt = false
            guard let genre = item.genres.first else { return }
            let found = (try? await Cinemeta.catalog(item.kind, .popular, genre: genre)) ?? []
            // Titles sharing a second genre too come first.
            let others = item.genres.dropFirst()
            items = found.filter { $0.id != item.id }
                .sorted { lhs, rhs in
                    let a = lhs.genres.contains { others.contains($0) }, b = rhs.genres.contains { others.contains($0) }
                    return a && !b
                }
                .prefix(16).map { $0 }
        }
    }
}

/// A cast member with their photo, when TMDB is set up.
private struct CastCard: View {
    let name: String
    @State private var photo: URL?

    var body: some View {
        VStack(spacing: 6) {
            PersonPhoto(name: name, photo: photo, size: 64)
            Text(name).font(.caption.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center)
        }
        .frame(width: 84)
        .task(id: name) { photo = await TMDB.shared.person(named: name)?.photo }
    }
}
