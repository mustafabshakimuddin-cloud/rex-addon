import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var playback: PlaybackCenter
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var downloads: DownloadStore
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let metrics = CardMetrics(sizeClass)
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if library.continueWatching.isEmpty && library.watchlist.isEmpty && downloads.items.isEmpty {
                    StateMessage(title: "Nothing here yet",
                                 message: "Titles you add to My List, things you start watching and downloads show up here.",
                                 systemImage: "rectangle.stack")
                        .padding(.top, 80)
                }
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
                            Button(role: .destructive) { library.clearProgress(entry) } label: { Label("Remove", systemImage: "xmark") }
                        }
                    }
                }
                if !downloads.items.isEmpty {
                    DownloadsSection(width: metrics.landscape)
                }
                if !library.watchlist.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("My List").font(.title3.weight(.bold)).padding(.horizontal, 20)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: metrics.poster, maximum: metrics.poster * 1.35), spacing: 14, alignment: .top)], spacing: 22) {
                            ForEach(library.watchlist) { item in
                                NavigationLink(value: item) { PosterCard(item: item, width: metrics.poster) }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button(role: .destructive) { library.toggleWatchlist(item) } label: { Label("Remove from My List", systemImage: "minus.circle") }
                                    }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .background(Theme.Backdrop())
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { router.showingSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
            }
        }
        .navigationDestination(for: MediaItem.self) { DetailView(item: $0) }
    }
}

/// Downloads, newest first, with progress and the controls each state allows.
struct DownloadsSection: View {
    let width: CGFloat
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var playback: PlaybackCenter
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: Library

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Downloads").font(.title3.weight(.bold))
                Spacer()
                Text(storageLine).font(.caption).foregroundStyle(Theme.secondaryText)
            }
            .padding(.horizontal, 20)
            VStack(spacing: 10) {
                ForEach(downloads.ordered) { item in row(item) }
            }
            .padding(.horizontal, 20)
        }
    }

    private var storageLine: String {
        let used = ByteCountFormatter.string(fromByteCount: downloads.usedBytes, countStyle: .file)
        guard let free = downloads.freeBytes else { return used }
        return "\(used) used · \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free"
    }

    private func row(_ item: DownloadItem) -> some View {
        HStack(spacing: 14) {
            RemoteImage(url: item.target.episode?.thumbnail ?? item.target.item.background ?? item.target.item.poster, targetWidth: 120)
                .frame(width: 112, height: 63)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(item.target.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    QualityBadge(quality: item.source.quality)
                    Text(status(item)).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
                }
                if !item.isFinished {
                    ProgressView(value: item.fraction).tint(Theme.accent)
                }
            }
            Spacer(minLength: 4)
            control(item)
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contextMenu {
            if item.isFinished {
                Button { playback.play(item.target, settings: settings, library: library) } label: { Label("Play", systemImage: "play.fill") }
            }
            Button(role: .destructive) { downloads.delete(item) } label: { Label("Delete Download", systemImage: "trash") }
        }
    }

    @ViewBuilder private func control(_ item: DownloadItem) -> some View {
        switch item.state {
        case .finished:
            Button { playback.play(item.target, settings: settings, library: library) } label: {
                Image(systemName: "play.fill").font(.headline)
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Play \(item.target.displayTitle)")
        case .downloading:
            Button { downloads.pause(item) } label: { Image(systemName: "pause.fill").font(.headline) }
                .buttonStyle(.glass)
                .accessibilityLabel("Pause")
        case .paused:
            Button { downloads.resume(item) } label: { Image(systemName: "arrow.down").font(.headline) }
                .buttonStyle(.glass)
                .accessibilityLabel("Resume")
        case .failed:
            Button { downloads.resume(item) } label: { Image(systemName: "arrow.clockwise").font(.headline) }
                .buttonStyle(.glass)
                .accessibilityLabel("Retry")
        }
    }

    private func status(_ item: DownloadItem) -> String {
        switch item.state {
        case .finished:
            return item.expected > 0 ? ByteCountFormatter.string(fromByteCount: item.expected, countStyle: .file) : "Downloaded"
        case .downloading:
            guard item.expected > 0 else { return "Starting…" }
            return "\(ByteCountFormatter.string(fromByteCount: item.written, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: item.expected, countStyle: .file))"
        case .paused: return "Paused · \(Int(item.fraction * 100))%"
        case let .failed(message): return message
        }
    }
}
