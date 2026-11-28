import SwiftUI

/// Everything already in the debrid account, newest first: open one to see its video files, tap a
/// file to play it. Nothing here adds to the account.
struct DebridCloudView: View {
    @Environment(AppSettings.self) private var settings
    @State private var entries: [DebridCloud.Entry] = []
    @State private var loading = true
    @State private var error: String?
    @State private var query = ""

    private var shown: [DebridCloud.Entry] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        return entries
            .filter { entry in words.allSatisfy { entry.name.lowercased().contains($0) } }
            .sorted { ($0.added ?? .distantPast) > ($1.added ?? .distantPast) }
    }

    var body: some View {
        List {
            if loading && entries.isEmpty {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            } else if let error, entries.isEmpty {
                StateMessage(title: "Couldn't load your files", message: error, actionTitle: "Retry") {
                    Task { await load() }
                }
                .listRowBackground(Color.clear)
            } else if entries.isEmpty {
                StateMessage(title: "Nothing here yet", message: "Releases you play or download through \(settings.debridService.name) appear here.",
                             systemImage: "tray")
                    .listRowBackground(Color.clear)
            }
            ForEach(shown) { entry in
                NavigationLink {
                    DebridCloudFilesView(entry: entry)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                        HStack(spacing: 8) {
                            if entry.bytes > 0 { Text(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file)) }
                            if let added = entry.added { Text(added.formatted(date: .abbreviated, time: .omitted)) }
                            if !entry.ready { Label("Not ready", systemImage: "hourglass").foregroundStyle(Theme.warning) }
                        }
                        .font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                }
                .disabled(!entry.ready)
            }
        }
        .groupedList()
        .clearListBackground()
        .background(Theme.Backdrop())
        .navigationTitle("\(settings.debridService.name) Files")
        .searchable(text: $query, prompt: "Search your files")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            entries = try await DebridCloud.list(service: settings.debridService, key: settings.debridKey)
            error = nil
        } catch {
            self.error = PlaybackError.describe(error)
        }
    }
}

/// The video files of one release in the account.
private struct DebridCloudFilesView: View {
    let entry: DebridCloud.Entry
    @Environment(AppSettings.self) private var settings
    @Environment(PlaybackCenter.self) private var playback
    @State private var files: [DebridCloud.File] = []
    @State private var loading = true
    @State private var error: String?
    @State private var opening: String?

    var body: some View {
        List {
            if loading && files.isEmpty {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            } else if let error, files.isEmpty {
                StateMessage(title: "Couldn't list the files", message: error).listRowBackground(Color.clear)
            } else if files.isEmpty {
                StateMessage(title: "No video files", message: "This release has nothing that plays.", systemImage: "film.stack")
                    .listRowBackground(Color.clear)
            }
            ForEach(files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { file in
                Button { open(file) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(file.name).font(.subheadline.weight(.medium)).lineLimit(2)
                            if file.bytes > 0 {
                                Text(ByteCountFormatter.string(fromByteCount: file.bytes, countStyle: .file))
                                    .font(.caption).foregroundStyle(Theme.secondaryText)
                            }
                        }
                        Spacer()
                        if opening == file.id { ProgressView() } else { Image(systemName: "play.fill").foregroundStyle(Theme.accent) }
                    }
                }
                .cardButton()
                .disabled(opening != nil)
            }
        }
        .groupedList()
        .clearListBackground()
        .background(Theme.Backdrop())
        .navigationTitle(entry.name)
        .inlineNavigationTitle()
        .task {
            defer { loading = false }
            do {
                files = try await DebridCloud.files(of: entry, service: settings.debridService, key: settings.debridKey)
            } catch {
                self.error = PlaybackError.describe(error)
            }
        }
    }

    private func open(_ file: DebridCloud.File) {
        opening = file.id
        Task {
            defer { opening = nil }
            do {
                let url = try await DebridCloud.link(for: file, service: settings.debridService, key: settings.debridKey)
                playback.playCloudFile(name: file.name, size: file.bytes, url: url)
            } catch {
                playback.errorMessage = PlaybackError.describe(error)
            }
        }
    }
}
