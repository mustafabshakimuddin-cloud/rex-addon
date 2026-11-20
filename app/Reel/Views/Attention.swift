import SwiftUI

/// Everything waiting on you, gathered from the stores that know about it. Home shows these as
/// cards; the count of those that need you is the red badge on the Home tab.
struct Attention {
    struct Item: Identifiable {
        enum Action { case setup, settings(SettingsPage), downloads, calendar }

        let id: String
        let title: String
        let detail: String
        let systemImage: String
        let tint: Color
        /// Counts toward the badge: something you should do, not just news.
        let needsYou: Bool
        let action: Action
        var progress: Double?
    }

    let items: [Item]

    @MainActor
    init(settings: AppSettings, library: Library, downloads: DownloadStore, trakt: TraktStore, upcoming: UpcomingStore) {
        var items: [Item] = []
        if !settings.canFindSources {
            items.append(Item(id: "setup", title: "Finish setting up",
                              detail: "Choose a debrid service or an addon so titles can play.",
                              systemImage: "wand.and.stars", tint: Theme.attention, needsYou: true, action: .setup))
        }
        if let error = trakt.syncError {
            items.append(Item(id: "trakt", title: "Trakt sync stopped", detail: error,
                              systemImage: "arrow.triangle.2.circlepath", tint: Theme.warning, needsYou: true,
                              action: .settings(.trakt)))
        }
        let failed = downloads.problems
        if !failed.isEmpty {
            items.append(Item(id: "downloads.failed", title: failed.count == 1 ? "A download failed" : "\(failed.count) downloads failed",
                              detail: failed.map(\.target.displayTitle).prefix(2).joined(separator: ", "),
                              systemImage: "exclamationmark.arrow.triangle.2.circlepath", tint: Theme.problem, needsYou: true,
                              action: .downloads))
        }
        let fresh = upcoming.newEpisodes(library)
        if !fresh.isEmpty {
            items.append(Item(id: "episodes.new", title: fresh.count == 1 ? "1 new episode" : "\(fresh.count) new episodes",
                              detail: fresh.map(\.item.name).prefix(3).joined(separator: ", "),
                              systemImage: "sparkles.tv", tint: Theme.accent, needsYou: true, action: .calendar))
        }
        let active = downloads.active
        if !active.isEmpty {
            let written = active.reduce(Int64(0)) { $0 + $1.written }
            let expected = active.reduce(Int64(0)) { $0 + $1.expected }
            items.append(Item(id: "downloads.active", title: active.count == 1 ? "Downloading 1 title" : "Downloading \(active.count) titles",
                              detail: active.map(\.target.displayTitle).prefix(2).joined(separator: ", "),
                              systemImage: "arrow.down.circle", tint: Theme.accent, needsYou: false, action: .downloads,
                              progress: expected > 0 ? Double(written) / Double(expected) : nil))
        }
        let paused = downloads.paused
        if !paused.isEmpty {
            items.append(Item(id: "downloads.paused", title: paused.count == 1 ? "1 download paused" : "\(paused.count) downloads paused",
                              detail: "Resume in Downloads.", systemImage: "pause.circle", tint: Theme.secondaryText,
                              needsYou: false, action: .downloads))
        }
        let today = upcoming.airingToday.filter { !$0.hasAired }
        if !today.isEmpty {
            items.append(Item(id: "episodes.today", title: today.count == 1 ? "1 episode airs today" : "\(today.count) episodes air today",
                              detail: today.map { "\($0.item.name) \($0.date.formatted(date: .omitted, time: .shortened))" }.prefix(2).joined(separator: ", "),
                              systemImage: "calendar.badge.clock", tint: Theme.accent, needsYou: false, action: .calendar))
        }
        self.items = items
    }

    var badgeCount: Int { items.filter(\.needsYou).count }

    /// The settings gear's red dot: a problem only Settings can fix.
    @MainActor
    static func settingsNeedAttention(settings: AppSettings, trakt: TraktStore, alerts: AlertCenter) -> Bool {
        !settings.canFindSources || trakt.syncError != nil || alerts.unseenProblems > 0
    }
}

/// Home's "Waiting on You" row: one glass card per item, each opening where it can be dealt with.
struct AttentionStrip: View {
    let attention: Attention
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        if !attention.items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("Waiting on You").font(.title3.weight(.bold))
                    if attention.badgeCount > 0 { AttentionDot() }
                }
                .padding(.horizontal, 20)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(attention.items) { item in
                            Button { perform(item.action) } label: { card(item) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .scrollClipDisabled()
            }
        }
    }

    private func card(_ item: Attention.Item) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(item.tint)
                .frame(width: 40, height: 40)
                .background(item.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if item.needsYou { AttentionDot(size: 7) }
                }
                Text(item.detail).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(2)
                if let progress = item.progress {
                    ProgressView(value: progress).tint(Theme.accent).padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
        .frame(minHeight: 72)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens where you can deal with it")
    }

    private func perform(_ action: Attention.Item.Action) {
        switch action {
        case .setup: router.openSetup()
        case let .settings(page): router.openSettings(page)
        case .downloads: router.homePath.append(LibraryPage.downloads)
        case .calendar: router.tab = .calendar
        }
    }
}
