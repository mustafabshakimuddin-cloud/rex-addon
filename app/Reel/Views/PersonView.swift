import SwiftUI

// MARK: - People

@MainActor
final class PersonModel: ObservableObject {
    @Published var movies: [MediaItem] = []
    @Published var series: [MediaItem] = []
    @Published var directed: Set<String> = []
    @Published var isLoading = false
    @Published var error: String?
    private var loaded = ""

    func load(_ name: String) async {
        guard loaded != name else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let found = try await Cinemeta.person(name)
            guard !Task.isCancelled else { return }
            movies = found.movies
            series = found.series
            directed = found.directed
            error = nil
            loaded = name
        } catch {
            self.error = error.localizedDescription
        }
    }

    var all: [MediaItem] { movies + series }

    /// The best-rated few: what the person is known for.
    var knownFor: [MediaItem] {
        all.sorted { (Double($0.rating ?? "") ?? 0) > (Double($1.rating ?? "") ?? 0) }.prefix(10).map { $0 }
    }

    /// Everything, newest first.
    var filmography: [MediaItem] {
        all.sorted { ($0.year ?? "") > ($1.year ?? "") }
    }
}

/// A cast or crew member: what they're known for, then everything they're credited in.
struct PersonView: View {
    let name: String
    @State private var person: TMDB.Person?
    @State private var expandedBio = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 16) {
                    PersonPhoto(name: name, photo: person?.photo, size: 84)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name).font(.largeTitle.weight(.bold)).lineLimit(2).minimumScaleFactor(0.6)
                        Text(subtitle).font(.subheadline).foregroundStyle(Theme.secondaryText)
                    }
                }
                .padding(.horizontal, 20)
                if let bio = person?.biography {
                    Text(bio)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(expandedBio ? nil : 5)
                        .onTapGesture { withAnimation(.snappy) { expandedBio.toggle() } }
                        .padding(.horizontal, 20)
                        .frame(maxWidth: 760, alignment: .leading)
                }
                PersonResults(name: name)
            }
            .padding(.vertical, 12)
        }
        .background(Theme.Backdrop())
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: name) { person = await TMDB.shared.person(named: name, details: true) }
    }

    private var subtitle: String {
        var parts = [person?.department ?? "Cast and crew"]
        if let born = person?.birthday { parts.append("Born \(born)") }
        if let place = person?.birthplace { parts.append(place) }
        return parts.joined(separator: " · ")
    }
}

/// A person's photo from TMDB when there is one, otherwise their initials.
struct PersonPhoto: View {
    let name: String
    let photo: URL?
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            Circle().fill(Theme.accentGradient)
            Text(name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined())
                .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
            if let photo {
                RemoteImage(url: photo, targetWidth: size)
                    .clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Known For and Filmography for a name; used by the person page and Search's People scope.
struct PersonResults: View {
    let name: String
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: DownloadStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.cardScale) private var cardScale
    @StateObject private var model = PersonModel()

    var body: some View {
        let metrics = CardMetrics(sizeClass, scale: cardScale)
        VStack(alignment: .leading, spacing: 26) {
            if model.isLoading && model.all.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
            } else if let error = model.error, model.all.isEmpty {
                StateMessage(title: "Couldn't search", message: error, actionTitle: "Retry") {
                    Task { await model.load(name) }
                }
            } else if model.all.isEmpty {
                StateMessage(title: "No credits found", message: "Cinemeta lists nothing for “\(name)”.", systemImage: "person.crop.circle.badge.questionmark")
                    .padding(.top, 40)
            } else {
                HStack(spacing: 8) {
                    StatusPill(text: "\(model.movies.count) movies", systemImage: "film")
                    StatusPill(text: "\(model.series.count) series", systemImage: "tv")
                    if !model.directed.isEmpty {
                        StatusPill(text: "Directed \(model.directed.count)", systemImage: "megaphone", tint: Theme.accent)
                    }
                }
                .padding(.horizontal, 20)
                ShelfRow(title: "Known For", items: model.knownFor) { item in
                    NavigationLink(value: item) { PosterCard(item: item, width: metrics.poster, mark: library.mark(for: item, downloads: downloads)) }
                        .buttonStyle(.plain)
                        .contextMenu { TitleContextMenu(item: item) }
                }
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Filmography", subtitle: "Newest first").padding(.horizontal, 20)
                    LazyVStack(spacing: 10) {
                        ForEach(model.filmography) { item in
                            NavigationLink(value: item) {
                                MediaRow(item: item) {
                                    if model.directed.contains(item.id) {
                                        StatusPill(text: "Director", tint: Theme.accent)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .contextMenu { TitleContextMenu(item: item) }
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
        .task(id: name) {
            try? await Task.sleep(nanoseconds: 300_000_000)  // debounce typing in Search
            guard !Task.isCancelled else { return }
            await model.load(name)
        }
    }
}
