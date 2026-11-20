import SwiftUI

enum CalendarLayout: String, CaseIterable, Identifiable {
    case cards, list
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var systemImage: String { self == .cards ? "rectangle.grid.2x2" : "list.bullet" }
}

/// New and upcoming episodes of the series you follow, day by day. Cards shows each episode's
/// picture; List is compact. Recent looks back a month for what you may have missed.
struct CalendarView: View {
    @EnvironmentObject private var upcoming: UpcomingStore
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var playback: PlaybackCenter
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var router: AppRouter
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.cardScale) private var cardScale
    @AppStorage("calendar.layout") private var layout: CalendarLayout = .cards
    @State private var span: Span = .upcoming

    enum Span: String, CaseIterable, Identifiable {
        case upcoming = "Upcoming", recent = "Recent"
        var id: String { rawValue }
    }

    private struct Day: Identifiable {
        let date: Date
        let episodes: [CalendarEpisode]
        var id: Date { date }
    }

    private var days: [Day] {
        let calendar = Calendar.current
        let source = span == .upcoming ? upcoming.upcoming + upcoming.airingToday.filter(\.hasAired) : upcoming.recent
        var seen = Set<String>()
        let unique = source.filter { seen.insert($0.id).inserted }
        let grouped = Dictionary(grouping: unique) { calendar.startOfDay(for: $0.date) }
        let keys = span == .upcoming ? grouped.keys.sorted() : grouped.keys.sorted(by: >)
        return keys.map { key in
            Day(date: key, episodes: (grouped[key] ?? []).sorted { ($0.date, $0.item.name, $0.episode.number) < ($1.date, $1.item.name, $1.episode.number) })
        }
    }

    var body: some View {
        let metrics = CardMetrics(sizeClass, scale: cardScale)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24, pinnedViews: [.sectionHeaders]) {
                Picker("Show", selection: $span) {
                    ForEach(Span.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                .padding(.horizontal, 20)

                if UpcomingStore.followedSeries(library).isEmpty {
                    StateMessage(title: "No series yet",
                                 message: "Add series to My List, or start watching one, and their new episodes appear here.",
                                 systemImage: "calendar.badge.plus", actionTitle: "Explore Series") {
                        router.exploreKind = .series
                        router.tab = .explore
                    }
                    .padding(.top, 40)
                } else if upcoming.isLoading && upcoming.episodes.isEmpty {
                    ProgressView("Checking your series…").frame(maxWidth: .infinity).padding(.top, 60)
                } else if let error = upcoming.error, upcoming.episodes.isEmpty {
                    StateMessage(title: "Couldn't load the calendar", message: error, actionTitle: "Retry") {
                        Task { await upcoming.refresh(library, force: true) }
                    }
                } else if days.isEmpty {
                    StateMessage(title: span == .upcoming ? "Nothing scheduled" : "Nothing recent",
                                 message: span == .upcoming ? "None of your series has a date for its next episode yet."
                                                            : "None of your series aired an episode in the last month.",
                                 systemImage: "calendar")
                        .padding(.top, 40)
                } else {
                    ForEach(days) { day in
                        Section {
                            switch layout {
                            case .cards:
                                LazyVGrid(columns: metrics.landscapeColumns, spacing: 16) {
                                    ForEach(day.episodes) { entry in card(entry, width: metrics.landscape) }
                                }
                                .padding(.horizontal, 20)
                            case .list:
                                VStack(spacing: 8) {
                                    ForEach(day.episodes) { entry in row(entry) }
                                }
                                .padding(.horizontal, 20)
                            }
                        } header: {
                            dayHeader(day)
                        }
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .background(Theme.Backdrop())
        .navigationTitle("Calendar")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Picker("Layout", selection: $layout) {
                    ForEach(CalendarLayout.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                }
                .pickerStyle(.menu)
            }
        }
        .refreshable { await upcoming.refresh(library, force: true) }
    }

    private func dayHeader(_ day: Day) -> some View {
        let calendar = Calendar.current
        let title: String
        if calendar.isDateInToday(day.date) { title = "Today" }
        else if calendar.isDateInTomorrow(day.date) { title = "Tomorrow" }
        else if calendar.isDateInYesterday(day.date) { title = "Yesterday" }
        else { title = day.date.formatted(.dateTime.weekday(.wide).day().month(.wide)) }
        return HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            Text(day.episodes.count == 1 ? "1 episode" : "\(day.episodes.count) episodes")
                .font(.caption).foregroundStyle(Theme.secondaryText)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Theme.background.opacity(0.85))
    }

    private func subtitle(_ entry: CalendarEpisode) -> String {
        let time = entry.date.formatted(date: .omitted, time: .shortened)
        return "\(entry.episode.title) · \(entry.hasAired ? "Aired" : "Airs") \(time)"
    }

    private func card(_ entry: CalendarEpisode, width: CGFloat) -> some View {
        let watched = library.isWatched(entry.target)
        return NavigationLink(value: entry.item) {
            BannerCard(item: entry.item, width: width, image: entry.episode.thumbnail ?? entry.item.background,
                       eyebrow: entry.episode.code + (watched ? " · Watched" : (entry.hasAired ? " · New" : "")),
                       title: entry.item.name, subtitle: subtitle(entry))
                .opacity(watched ? 0.6 : 1)
        }
        .buttonStyle(.plain)
        .contextMenu { menu(entry) }
    }

    private func row(_ entry: CalendarEpisode) -> some View {
        let watched = library.isWatched(entry.target)
        return NavigationLink(value: entry.item) {
            HStack(spacing: 12) {
                RemoteImage(url: entry.item.poster, targetWidth: 50)
                    .frame(width: 44, height: 66)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.item.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("\(entry.episode.code) · \(entry.episode.title)").font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
                }
                Spacer(minLength: 6)
                if watched {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.cached).accessibilityLabel("Watched")
                } else {
                    Text(entry.date.formatted(date: .omitted, time: .shortened)).font(.caption.weight(.semibold)).monospacedDigit()
                }
            }
            .padding(10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { menu(entry) }
    }

    @ViewBuilder private func menu(_ entry: CalendarEpisode) -> some View {
        if entry.hasAired {
            Button { playback.play(entry.target, settings: settings, library: library) } label: { Label("Play", systemImage: "play.fill") }
            Button { playback.chooseSource(for: entry.target) } label: { Label("Choose Source", systemImage: "list.bullet.rectangle") }
            if library.isWatched(entry.target) {
                Button { library.markUnwatched(entry.target) } label: { Label("Mark as Unwatched", systemImage: "circle") }
            } else {
                Button { library.markWatched(entry.target) } label: { Label("Mark as Watched", systemImage: "checkmark.circle") }
            }
        }
        NavigationLink(value: entry.item) { Label("Go to Series", systemImage: "info.circle") }
        Button { library.toggleWatchlist(entry.item) } label: {
            Label(library.isInWatchlist(entry.item) ? "Remove from My List" : "Add to My List",
                  systemImage: library.isInWatchlist(entry.item) ? "minus.circle" : "plus.circle")
        }
    }
}
