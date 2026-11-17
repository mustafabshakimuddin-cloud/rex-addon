import SwiftUI

/// Card widths follow the size class, never the device, so they suit the folded and unfolded Duo alike.
struct CardMetrics {
    let poster: CGFloat
    let landscape: CGFloat

    init(_ sizeClass: UserInterfaceSizeClass?) {
        if sizeClass == .regular {
            poster = 160; landscape = 340
        } else {
            poster = 116; landscape = 260
        }
    }
}

struct PosterCard: View {
    let item: MediaItem
    let width: CGFloat
    var showTitle = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(url: item.poster)
                .frame(width: width, height: width * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if let rating = item.rating {
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
    }
}

struct ContinueCard: View {
    let entry: PlaybackProgress
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: entry.episode?.thumbnail ?? entry.item.background ?? entry.item.poster)
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
                GeometryReader { proxy in
                    Capsule().fill(.white.opacity(0.25)).frame(height: 4)
                        .overlay(alignment: .leading) {
                            Capsule().fill(Theme.accentGradient).frame(width: proxy.size.width * entry.fraction, height: 4)
                        }
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .padding(.horizontal, 10).padding(.bottom, 6)
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
        let minutes = Int(max(0, entry.duration - entry.position) / 60)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m left" : "\(minutes)m left"
    }
}

/// A titled horizontal row of cards.
struct ShelfRow<Data: RandomAccessCollection, Content: View>: View where Data.Element: Identifiable {
    let title: String
    let items: Data
    var spacing: CGFloat = 14
    @ViewBuilder let content: (Data.Element) -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.weight(.bold)).padding(.horizontal, 20)
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
