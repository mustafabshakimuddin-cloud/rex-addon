import SwiftUI

@MainActor
final class SourcesModel: ObservableObject {
    @Published var sources: [StreamSource] = []
    @Published var isLoading = true
    @Published var error: String?

    func load(_ target: PlaybackTarget, config: TorrentioConfig) async {
        isLoading = true
        defer { isLoading = false }
        do {
            sources = try await Torrentio.streams(kind: target.item.kind, videoID: target.videoID, config: config)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Every release Torrentio found, grouped by quality, with what matters for choosing one.
struct SourcesSheet: View {
    let target: PlaybackTarget
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var playback: PlaybackCenter
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = SourcesModel()
    @State private var quality = "All"
    @State private var order: Order = .best

    enum Order: String, CaseIterable, Identifiable {
        case best = "Best quality", largest = "Largest", smallest = "Smallest", seeders = "Most seeders"
        var id: String { rawValue }
    }

    private var qualities: [String] {
        let present = Set(model.sources.map(\.quality))
        return ["All"] + (StreamSource.qualityOrder + ["Other"]).filter(present.contains) + present.subtracting(StreamSource.qualityOrder + ["Other"]).sorted()
    }

    private var groups: [(String, [StreamSource])] {
        let shown = model.sources.filter { quality == "All" || $0.quality == quality }
        let grouped = Dictionary(grouping: shown, by: \.quality)
        return grouped.keys.sorted { lhs, rhs in
            let a = StreamSource.qualityOrder.firstIndex(of: lhs) ?? 99, b = StreamSource.qualityOrder.firstIndex(of: rhs) ?? 99
            return a == b ? lhs < rhs : a < b
        }.map { ($0, sorted(grouped[$0] ?? [])) }
    }

    /// Within a quality: instant sources first, then the chosen order. "Best" keeps Torrentio's own ranking.
    private func sorted(_ sources: [StreamSource]) -> [StreamSource] {
        let ranked: [StreamSource]
        switch order {
        case .best: ranked = sources
        case .largest: ranked = sources.sorted { $0.sizeBytes > $1.sizeBytes }
        case .smallest: ranked = sources.sorted { ($0.sizeBytes == 0 ? .infinity : $0.sizeBytes) < ($1.sizeBytes == 0 ? .infinity : $1.sizeBytes) }
        case .seeders: ranked = sources.sorted { ($0.seeders ?? 0) > ($1.seeders ?? 0) }
        }
        return ranked.filter(\.isCached) + ranked.filter { !$0.isCached }
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading {
                    ProgressView("Searching sources…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = model.error {
                    StateMessage(title: "Couldn't load sources", message: error, actionTitle: "Retry") {
                        Task { await model.load(target, config: settings.torrentio) }
                    }
                } else if model.sources.isEmpty {
                    StateMessage(title: "No sources", message: "Torrentio found nothing with your current filters.", systemImage: "tray")
                } else {
                    List {
                        if !settings.isDebridConfigured {
                            Label("Add a debrid service in Settings to play these.", systemImage: "info.circle")
                                .foregroundStyle(Theme.secondaryText)
                        }
                        ForEach(groups, id: \.0) { group in
                            Section("\(group.0) · \(group.1.count)") {
                                ForEach(group.1) { source in
                                    Button {
                                        playback.play(target, settings: settings, library: library, source: source, fromStart: playback.chooseFromStart)
                                        dismiss()
                                    } label: {
                                        SourceRow(source: source)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(!source.isPlayable)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.Backdrop())
            .navigationTitle(target.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Sort", selection: $order) {
                            ForEach(Order.allCases) { Text($0.rawValue).tag($0) }
                        }
                        if qualities.count > 2 {
                            Picker("Quality", selection: $quality) {
                                ForEach(qualities, id: \.self) { Text($0).tag($0) }
                            }
                        }
                    } label: {
                        Label("Sort and filter", systemImage: "line.3.horizontal.decrease")
                    }
                }
            }
        }
        .task { await model.load(target, config: settings.torrentio) }
    }
}

struct SourceRow: View {
    let source: StreamSource

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                QualityBadge(quality: source.quality)
                ForEach(source.tags.prefix(4), id: \.self) { tag in
                    Text(tag).font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                Spacer(minLength: 4)
                if let tag = source.debridTag {
                    Label(source.isCached ? "Instant" : "Download", systemImage: source.isCached ? "bolt.fill" : "arrow.down.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(source.isCached ? Theme.cached : Theme.secondaryText)
                        .accessibilityLabel(tag)
                }
            }
            Text(source.release).font(.subheadline.weight(.medium)).lineLimit(2)
            if let file = source.file, file != source.release {
                Text(file).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
            }
            HStack(spacing: 14) {
                if let size = source.size { Label(size, systemImage: "internaldrive") }
                if let seeders = source.seeders { Label("\(seeders)", systemImage: "person.2.fill") }
                if let provider = source.provider { Label(provider, systemImage: "globe") }
                if let languages = source.languages { Text(languages).lineLimit(1) }
            }
            .font(.caption)
            .foregroundStyle(Theme.secondaryText)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .opacity(source.isPlayable ? 1 : 0.5)
    }
}
