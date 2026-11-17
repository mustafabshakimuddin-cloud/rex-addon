import SwiftUI

@MainActor
final class DetailModel: ObservableObject {
    @Published var detail: MediaDetail?
    @Published var error: String?
    @Published var season: Int = 1

    func load(_ item: MediaItem, library: Library) async {
        guard detail == nil else { return }
        do {
            let loaded = try await Cinemeta.detail(item.kind, id: item.id)
            detail = loaded
            season = library.nextEpisode(in: loaded)?.season ?? loaded.seasons.first ?? 1
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct DetailView: View {
    let item: MediaItem
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var playback: PlaybackCenter
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.openURL) private var openURL
    @StateObject private var model = DetailModel()
    @State private var width: CGFloat = 390
    @State private var expandedOverview = false

    private var shown: MediaItem { model.detail?.item ?? item }
    private var wide: Bool { width >= 700 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                VStack(alignment: .leading, spacing: 26) {
                    overview
                    if let detail = model.detail, item.kind == .series, !detail.episodes.isEmpty {
                        episodesSection(detail)
                    }
                    if let detail = model.detail, !detail.cast.isEmpty { castSection(detail) }
                    if let error = model.error {
                        StateMessage(title: "Couldn't load details", message: error)
                    }
                }
                .padding(.horizontal, wide ? 48 : 20)
                .readableWidth(1100)
            }
            .padding(.bottom, 50)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
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
        }
        .task { await model.load(item, library: library) }
    }

    // MARK: Header

    private var headerHeight: CGFloat { wide ? min(max(width * 0.42, 380), 560) : min(width * 1.05, 520) }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: shown.background ?? shown.poster)
                .frame(width: width, height: headerHeight)
                .clipped()
            LinearGradient(stops: [
                .init(color: .clear, location: 0.25),
                .init(color: Theme.background.opacity(0.75), location: 0.7),
                .init(color: Theme.background, location: 1),
            ], startPoint: .top, endPoint: .bottom)
            if wide {
                LinearGradient(colors: [Theme.background.opacity(0.85), .clear], startPoint: .leading, endPoint: .center)
            }
            VStack(alignment: .leading, spacing: 14) {
                TitleLogo(item: shown, maxHeight: wide ? 120 : 90)
                    .frame(maxWidth: wide ? 460 : width * 0.8, alignment: .leading)
                metaLine
                actionButtons
            }
            .padding(.horizontal, wide ? 48 : 20)
            .padding(.bottom, 8)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: headerHeight)
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
        if item.kind == .movie { return PlaybackTarget(item: shown) }
        guard let detail = model.detail, let episode = library.nextEpisode(in: detail) else { return nil }
        return PlaybackTarget(item: shown, episode: episode)
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
            } else if item.kind == .series {
                ProgressView()
            }
            if let trailer = model.detail?.trailerYouTubeID, let url = URL(string: "https://www.youtube.com/watch?v=\(trailer)") {
                Button { openURL(url) } label: { Image(systemName: "film.stack").font(.headline) }
                    .buttonStyle(.glass)
                    .accessibilityLabel("Trailer")
            }
        }
    }

    private func playTitle(_ target: PlaybackTarget, resume: Double?) -> String {
        let verb = resume == nil ? "Play" : "Resume"
        guard let episode = target.episode else { return verb }
        return "\(verb) \(episode.code)"
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
                } label: {
                    Label(model.season == 0 ? "Specials" : "Season \(model.season)", systemImage: "chevron.up.chevron.down")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.glass)
            }
            LazyVGrid(columns: wide ? [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)] : [GridItem(.flexible())], spacing: 14) {
                ForEach(detail.episodes(in: model.season)) { episode in
                    EpisodeRow(episode: episode, progress: library.progress(for: PlaybackTarget(item: shown, episode: episode))) {
                        playback.play(PlaybackTarget(item: shown, episode: episode), settings: settings, library: library)
                    } chooseSource: {
                        playback.chooseSource(for: PlaybackTarget(item: shown, episode: episode))
                    }
                }
            }
        }
    }

    private func castSection(_ detail: MediaDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cast").font(.title3.weight(.bold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(detail.cast, id: \.self) { name in
                        Chip(text: name, systemImage: "person.fill")
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
    let play: () -> Void
    let chooseSource: () -> Void

    var body: some View {
        Button(action: play) {
            HStack(alignment: .top, spacing: 14) {
                ZStack(alignment: .bottom) {
                    RemoteImage(url: episode.thumbnail)
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
                    Image(systemName: progress?.isFinished == true ? "checkmark.circle.fill" : "play.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.35))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(width: 150, height: 150 * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .opacity(episode.hasAired ? 1 : 0.45)

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(episode.number). \(episode.title)").font(.subheadline.weight(.semibold)).lineLimit(2)
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
        }
    }
}
