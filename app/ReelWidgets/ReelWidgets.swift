import WidgetKit
import SwiftUI
import ActivityKit

@main
struct ReelWidgetBundle: WidgetBundle {
    var body: some Widget {
        ContinueWatchingWidget()
        UpcomingWidget()
        DownloadLiveActivity()
    }
}

// MARK: - Timeline

struct ReelEntry: TimelineEntry {
    let date: Date
    let data: WidgetData?
}

struct ReelProvider: TimelineProvider {
    func placeholder(in context: Context) -> ReelEntry { ReelEntry(date: Date(), data: Self.sample) }

    func getSnapshot(in context: Context, completion: @escaping (ReelEntry) -> Void) {
        completion(ReelEntry(date: Date(), data: context.isPreview ? Self.sample : WidgetData.load() ?? Self.sample))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ReelEntry>) -> Void) {
        // The app reloads the widgets whenever their data changes; an hourly refresh keeps
        // "airs today" honest when it doesn't.
        let entry = ReelEntry(date: Date(), data: WidgetData.load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(3600))))
    }

    static let sample = WidgetData(
        continueWatching: [
            .init(id: "1", title: "A Series", subtitle: "S02E04 · 23m left", fraction: 0.6, image: nil, link: URL(string: "reel://")!),
            .init(id: "2", title: "A Film", subtitle: "1h 12m left", fraction: 0.3, image: nil, link: URL(string: "reel://")!),
        ],
        upcoming: [.init(id: "3", title: "Another Series", subtitle: "S01E08 · Friday", fraction: nil, image: nil, link: URL(string: "reel://")!)])
}

// MARK: - Continue Watching

struct ContinueWatchingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ContinueWatching", provider: ReelProvider()) { entry in
            ContinueWatchingView(entries: entry.data?.continueWatching ?? [])
                .containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("Continue Watching")
        .description("Pick up where you left off.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct ContinueWatchingView: View {
    let entries: [WidgetData.Entry]
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if entries.isEmpty {
            EmptyWidget(text: "Nothing to continue yet.", symbol: "play.circle")
        } else if family == .systemSmall, let first = entries.first {
            Link(destination: first.link) { BigTile(entry: first) }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Continue Watching").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                ForEach(entries.prefix(family == .systemLarge ? 5 : 2)) { entry in
                    Link(destination: entry.link) { Row(entry: entry) }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Upcoming

struct UpcomingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Upcoming", provider: ReelProvider()) { entry in
            UpcomingView(entries: entry.data?.upcoming ?? [])
                .containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("Next Episodes")
        .description("When the series you follow come back.")
        .supportedFamilies([.systemMedium, .systemLarge, .accessoryRectangular])
    }
}

private struct UpcomingView: View {
    let entries: [WidgetData.Entry]
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if entries.isEmpty {
            EmptyWidget(text: "No episodes coming up.", symbol: "calendar")
        } else if family == .accessoryRectangular, let first = entries.first {
            VStack(alignment: .leading) {
                Text(first.title).font(.headline).lineLimit(1)
                Text(first.subtitle).font(.caption).lineLimit(1)
            }
            .widgetURL(first.link)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Next Episodes").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                ForEach(entries.prefix(family == .systemLarge ? 5 : 2)) { entry in
                    Link(destination: entry.link) { Row(entry: entry) }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Pieces

private struct Picture: View {
    let name: String?
    var body: some View {
        if let url = WidgetData.imageURL(name), let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            Rectangle().fill(.white.opacity(0.12))
        }
    }
}

private struct Row: View {
    let entry: WidgetData.Entry
    var body: some View {
        HStack(spacing: 10) {
            Picture(name: entry.image)
                .frame(width: 64, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(entry.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                if let fraction = entry.fraction { ProgressView(value: fraction).tint(.pink) }
            }
        }
    }
}

private struct BigTile: View {
    let entry: WidgetData.Entry
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Picture(name: entry.image)
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).font(.subheadline.weight(.bold)).lineLimit(2)
                Text(entry.subtitle).font(.caption2).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                if let fraction = entry.fraction { ProgressView(value: fraction).tint(.pink) }
            }
            .padding(10)
        }
    }
}

private struct EmptyWidget: View {
    let text: String
    let symbol: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.title2)
            Text(text).font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Download Live Activity

struct DownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: context.state.finished ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .font(.title2).foregroundStyle(.pink)
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.attributes.title).font(.headline).lineLimit(1)
                    Text(context.state.detail).font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: context.state.fraction).tint(.pink)
                }
            }
            .padding()
            .activityBackgroundTint(.black.opacity(0.8))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.pink)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(Int(context.state.fraction * 100))%").monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading) {
                        Text(context.attributes.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        ProgressView(value: context.state.fraction).tint(.pink)
                    }
                }
            } compactLeading: {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.pink)
            } compactTrailing: {
                Text("\(Int(context.state.fraction * 100))%").monospacedDigit().font(.caption2)
            } minimal: {
                Image(systemName: "arrow.down").foregroundStyle(.pink)
            }
        }
    }
}
