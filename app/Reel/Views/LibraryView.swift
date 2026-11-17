import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var playback: PlaybackCenter
    @EnvironmentObject private var router: AppRouter
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let metrics = CardMetrics(sizeClass)
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if library.continueWatching.isEmpty && library.watchlist.isEmpty {
                    StateMessage(title: "Nothing here yet",
                                 message: "Titles you add to My List and things you start watching show up here.",
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
