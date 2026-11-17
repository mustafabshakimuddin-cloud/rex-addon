import SwiftUI

enum AppTab: Hashable {
    case home, movies, series, library, search
}

/// App-wide navigation requests that aren't owned by one screen.
@MainActor
final class AppRouter: ObservableObject {
    @Published var showingSettings = false
}

struct RootView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var playback: PlaybackCenter
    @EnvironmentObject private var router: AppRouter
    @State private var tab: AppTab = .home

    var body: some View {
        // A system TabView, not a hand-drawn bar: iOS 27 gives it Liquid Glass, and on the
        // unfolded iPhone Duo (and iPad) the adaptable style turns it into a side rail/sidebar.
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                NavigationStack { HomeView() }
            }
            Tab("Movies", systemImage: "film", value: AppTab.movies) {
                NavigationStack { BrowseView(kind: .movie) }
            }
            Tab("Series", systemImage: "tv", value: AppTab.series) {
                NavigationStack { BrowseView(kind: .series) }
            }
            Tab("Library", systemImage: "rectangle.stack.fill", value: AppTab.library) {
                NavigationStack { LibraryView() }
            }
            Tab(value: AppTab.search, role: .search) {
                NavigationStack { SearchView() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        .overlay(alignment: .bottom) { preparingHUD }
        // Five tabs fit an iPhone tab bar without a "More" tab; Settings is a gear and a sheet.
        .sheet(isPresented: $router.showingSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { router.showingSettings = false }
                        }
                    }
            }
        }
        .sheet(item: $playback.choosingSource) { target in
            SourcesSheet(target: target)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $playback.session) { session in
            PlayerView(session: session)
        }
        .alert("Couldn't play", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(playback.errorMessage ?? "")
        }
        .alert("Add a debrid service", isPresented: $playback.needsDebridSetup) {
            Button("Open Settings") { router.showingSettings = true }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Streams play through a debrid service such as Real-Debrid. Add your service and API key in Settings.")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { playback.errorMessage != nil }, set: { if !$0 { playback.errorMessage = nil } })
    }

    @ViewBuilder private var preparingHUD: some View {
        if let target = playback.preparing {
            HStack(spacing: 12) {
                ProgressView().tint(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Preparing stream").font(.subheadline.weight(.semibold))
                    Text(target.displayTitle).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button("Cancel") { playback.cancel() }
                    .buttonStyle(.glass)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: 460)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
            .padding(.horizontal, 16)
            .padding(.bottom, 90)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.spring(duration: 0.35), value: playback.preparing)
        }
    }
}
