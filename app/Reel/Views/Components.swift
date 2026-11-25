import SwiftUI

extension EnvironmentValues {
    /// Settings → Appearance → Poster size, as a multiplier on card widths.
    @Entry var cardScale: CGFloat = 1
    /// Settings → Appearance → Show ratings on posters.
    @Entry var showsRatings: Bool = true
}

/// Card widths follow the size class, never the device, so they suit the folded and unfolded Duo alike.
struct CardMetrics {
    let poster: CGFloat
    let landscape: CGFloat

    init(_ sizeClass: UserInterfaceSizeClass?, scale: CGFloat = 1) {
        if sizeClass == .regular {
            poster = 160 * scale; landscape = 340 * scale
        } else {
            poster = 116 * scale; landscape = 260 * scale
        }
    }

    /// An adaptive grid of posters.
    var posterColumns: [GridItem] {
        [GridItem(.adaptive(minimum: poster, maximum: poster * 1.35), spacing: 14, alignment: .top)]
    }

    /// An adaptive grid of landscape cards.
    var landscapeColumns: [GridItem] {
        [GridItem(.adaptive(minimum: landscape, maximum: landscape * 1.6), spacing: 16, alignment: .top)]
    }
}

struct PosterCard: View {
    let item: MediaItem
    let width: CGFloat
    var showTitle = true
    /// A small mark in the corner for a title that is in your library: watched, downloaded, listed.
    var mark: PosterMark?
    @Environment(\.showsRatings) private var showsRatings

    enum PosterMark {
        case watched, downloaded, listed, progress(Double)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(url: item.poster, targetWidth: width)
                .frame(width: width, height: width * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .topLeading) { markView }
                .overlay(alignment: .bottom) {
                    if case let .progress(fraction)? = mark {
                        GeometryReader { proxy in
                            Capsule().fill(.white.opacity(0.25)).frame(height: 4)
                                .overlay(alignment: .leading) {
                                    Capsule().fill(Theme.accentGradient).frame(width: proxy.size.width * fraction, height: 4)
                                }
                                .frame(maxHeight: .infinity, alignment: .bottom)
                        }
                        .padding(8)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if showsRatings, let rating = item.rating {
                        Label(rating, systemImage: "star.fill")
                            .font(.caption2.weight(.bold))
                            .labelStyle(.titleAndIcon)
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .glassEffect(.regular, in: .capsule)
                            .padding(6)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.08)))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
            if showTitle {
                Text(item.name).font(.footnote.weight(.semibold)).lineLimit(1)
                Text(item.year ?? " ").font(.caption2).foregroundStyle(Theme.secondaryText).lineLimit(1)
            }
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        // One element for VoiceOver: the title, its facts and what you've done with it.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [item.name]
        if let year = item.year { parts.append(year) }
        if let rating = item.rating { parts.append("rated \(rating)") }
        switch mark {
        case .watched?: parts.append("watched")
        case .downloaded?: parts.append("downloaded")
        case .listed?: parts.append("in My List")
        case let .progress(fraction)?: parts.append("\(Int(fraction * 100)) percent watched")
        case nil: break
        }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder private var markView: some View {
        switch mark {
        case .watched?: cornerIcon("checkmark", tint: Theme.cached, label: "Watched")
        case .downloaded?: cornerIcon("arrow.down", tint: Theme.accent, label: "Downloaded")
        case .listed?: cornerIcon("bookmark.fill", tint: .white, label: "In My List")
        default: EmptyView()
        }
    }

    private func cornerIcon(_ symbol: String, tint: Color, label: String) -> some View {
        Image(systemName: symbol)
            .font(.caption2.weight(.heavy))
            .foregroundStyle(tint)
            .frame(width: 24, height: 24)
            .glassEffect(.regular, in: .circle)
            .padding(6)
            .accessibilityLabel(label)
    }
}

extension Library {
    /// The corner mark a poster gets for what you've done with that title.
    func mark(for item: MediaItem, downloads: DownloadStore? = nil) -> PosterCard.PosterMark? {
        if item.kind == .movie {
            let target = PlaybackTarget(item: item)
            if isWatched(target) { return .watched }
            if let entry = progress(for: target), entry.position >= Library.minimumResume { return .progress(entry.fraction) }
            if downloads?.item(for: target)?.isFinished == true { return .downloaded }
        }
        return isInWatchlist(item) ? .listed : nil
    }
}

/// A wide card with the title's backdrop and logo: Library's Banners layout and Calendar's cards.
struct BannerCard: View {
    let item: MediaItem
    let width: CGFloat
    var image: URL?
    var eyebrow: String?
    var title: String?
    var subtitle: String?
    var fraction: Double?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: image ?? item.background ?? item.poster, targetWidth: width * 0.8)
                .frame(width: width, height: width * 9 / 16)
            LinearGradient(stops: [
                .init(color: .clear, location: 0.3),
                .init(color: .black.opacity(0.85), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 4) {
                if let eyebrow {
                    Text(eyebrow.uppercased()).font(.caption2.weight(.heavy)).foregroundStyle(Theme.accent).lineLimit(1)
                }
                if let title {
                    Text(title).font(.headline).lineLimit(1)
                } else {
                    TitleLogo(item: item, maxHeight: 44)
                        .frame(maxWidth: width * 0.6, alignment: .leading)
                }
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.8)).lineLimit(2)
                }
                if let fraction {
                    ProgressView(value: fraction).tint(Theme.accent)
                }
            }
            .padding(12)
        }
        .frame(width: width, height: width * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .contentShape(Rectangle())
    }
}

/// One title as a row: poster thumbnail, name, facts and an optional trailing status.
struct MediaRow<Trailing: View>: View {
    let item: MediaItem
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 14) {
            RemoteImage(url: item.poster, targetWidth: 60)
                .frame(width: 54, height: 81)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(subtitle ?? HeroCarousel.subtitle(for: item))
                    .font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(2)
                if let rating = item.rating {
                    Label(rating, systemImage: "star.fill").font(.caption2.weight(.bold)).foregroundStyle(.yellow)
                }
            }
            Spacer(minLength: 6)
            trailing()
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
    }
}

extension MediaRow where Trailing == EmptyView {
    init(item: MediaItem, subtitle: String? = nil) {
        self.init(item: item, subtitle: subtitle) { EmptyView() }
    }
}

/// A small coloured label: "In My List", "Downloaded", "FAIL".
struct StatusPill: View {
    let text: String
    var systemImage: String?
    var tint: Color = .white

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(tint.opacity(0.16), in: Capsule())
    }
}

/// The red dot on anything that is waiting on you.
struct AttentionDot: View {
    var size: CGFloat = 9
    var body: some View {
        Circle().fill(Theme.attention)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(.black.opacity(0.4), lineWidth: 1))
            .accessibilityLabel("Needs attention")
    }
}

/// A shelf or section title, with an optional "See All" on the right.
struct SectionHeader<Destination: View>: View {
    let title: String
    var subtitle: String?
    var destination: (() -> Destination)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.bold))
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(Theme.secondaryText)
                }
            }
            Spacer()
            if let destination {
                NavigationLink {
                    destination()
                } label: {
                    HStack(spacing: 3) {
                        Text("See All")
                        Image(systemName: "chevron.right").font(.caption.weight(.bold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                }
            }
        }
    }
}

extension SectionHeader where Destination == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle, destination: nil)
    }
}

struct ContinueCard: View {
    let entry: PlaybackProgress
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: entry.episode?.thumbnail ?? entry.item.background ?? entry.item.poster, targetWidth: width * 0.75)
                    .frame(width: width, height: width * 9 / 16)
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                HStack(spacing: 8) {
                    Image(systemName: "play.fill").font(.caption.weight(.bold))
                        .frame(width: 30, height: 30)
                        .glassEffect(.regular.interactive(), in: .circle)
                    Text(remaining).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.9))
                }
                .padding(10)
                .padding(.bottom, 4)
                if !entry.isUpNext {
                    GeometryReader { proxy in
                        Capsule().fill(.white.opacity(0.25)).frame(height: 4)
                            .overlay(alignment: .leading) {
                                Capsule().fill(Theme.accentGradient).frame(width: proxy.size.width * entry.fraction, height: 4)
                            }
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                    .padding(.horizontal, 10).padding(.bottom, 6)
                }
            }
            .frame(width: width, height: width * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.08)))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.item.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let episode = entry.episode {
                    Text("\(episode.code) · \(episode.title)").font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
                }
            }
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var remaining: String {
        if entry.isUpNext { return "Next episode" }
        let minutes = Int(max(0, entry.duration - entry.position) / 60)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m left" : "\(minutes)m left"
    }
}

/// A titled horizontal row of cards.
struct ShelfRow<Data: RandomAccessCollection, Content: View, Destination: View>: View where Data.Element: Identifiable {
    let title: String
    var subtitle: String?
    let items: Data
    var spacing: CGFloat = 14
    /// Where "See All" goes; no button without one.
    var seeAll: (() -> Destination)?
    @ViewBuilder let content: (Data.Element) -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title, subtitle: subtitle, destination: seeAll).padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: spacing) {
                    ForEach(items) { content($0) }
                }
                .padding(.horizontal, 20)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollClipDisabled()
        }
    }
}

extension ShelfRow where Destination == EmptyView {
    init(title: String, subtitle: String? = nil, items: Data, spacing: CGFloat = 14,
         @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.init(title: title, subtitle: subtitle, items: items, spacing: spacing, seeAll: nil, content: content)
    }
}

struct Chip: View {
    let text: String
    var systemImage: String?
    var tint: Color?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .foregroundStyle(tint ?? .white)
        .glassEffect(tint.map { Glass.regular.tint($0.opacity(0.25)) } ?? .regular, in: .capsule)
    }
}

struct QualityBadge: View {
    let quality: String
    var body: some View {
        Text(quality)
            .font(.caption.weight(.heavy))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(quality == "4K" ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.white.opacity(0.14)), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct StateMessage: View {
    let title: String
    let message: String
    var systemImage = "exclamationmark.triangle"
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.glassProminent)
            }
        }
    }
}

extension View {
    /// Keeps reading width comfortable on the unfolded Duo, iPad and wide windows.
    func readableWidth(_ maxWidth: CGFloat = 980) -> some View {
        frame(maxWidth: maxWidth).frame(maxWidth: .infinity)
    }
}

/// Scrolls a tab's first screen back to the top when its tab is chosen again.
private struct ScrollToTopOnRetap: ViewModifier {
    let tab: AppTab
    @EnvironmentObject private var router: AppRouter
    @State private var position = ScrollPosition(edge: .top)

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onChange(of: router.scrollToTop) { _, chosen in
                guard chosen == tab else { return }
                withAnimation(.snappy) { position.scrollTo(edge: .top) }
                router.didScrollToTop()
            }
    }
}

extension View {
    func scrollsToTopOnRetap(_ tab: AppTab) -> some View { modifier(ScrollToTopOnRetap(tab: tab)) }
}
