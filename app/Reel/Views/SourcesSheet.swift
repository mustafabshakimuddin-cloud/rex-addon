import SwiftUI

@MainActor
final class SourcesModel: ObservableObject {
    @Published var sources: [StreamSource] = []
    @Published var isLoading = true
    @Published var error: String?
    @Published var verifying: Set<String> = []
    @Published var verifyErrors: [String: String] = [:]

    func load(_ target: PlaybackTarget, playback: PlaybackCenter, query: SourceQuery, refresh: Bool = false) async {
        if !refresh, let cached = playback.cachedSources(for: target, query: query) {
            sources = cached
            isLoading = false
            return
        }
        isLoading = sources.isEmpty
        defer { isLoading = false }
        do {
            sources = try await playback.sources(for: target, query: query, refresh: refresh)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func verify(_ source: StreamSource, playback: PlaybackCenter) {
        guard !verifying.contains(source.fileKey) else { return }
        verifying.insert(source.fileKey)
        verifyErrors[source.fileKey] = nil
        Task {
            do {
                _ = try await playback.verify(source)
            } catch {
                verifyErrors[source.fileKey] = error.localizedDescription
            }
            verifying.remove(source.fileKey)
        }
    }
}

/// Every release found, grouped by quality, with what matters for choosing one: what history says
/// about it, and what the file really contains once checked.
struct SourcesSheet: View {
    let target: PlaybackTarget
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var playback: PlaybackCenter
    @EnvironmentObject private var memory: SourceMemory
    @EnvironmentObject private var downloads: DownloadStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = SourcesModel()
    @State private var quality = "All"
    @State private var order: Order = .best

    enum Order: String, CaseIterable, Identifiable {
        case best = "Best for you", largest = "Largest", smallest = "Smallest", seeders = "Most seeders"
        var id: String { rawValue }
    }

    private var qualities: [String] {
        let present = Set(model.sources.map(\.quality))
        return ["All"] + (StreamSource.qualityOrder + ["Other"]).filter(present.contains) + present.subtracting(StreamSource.qualityOrder + ["Other"]).sorted()
    }

    private var recommended: StreamSource? {
        SourceRanker.rank(model.sources, memory: memory).first { $0.isCached || !settings.isDebridConfigured }
    }

    private var groups: [(String, [StreamSource])] {
        let shown = model.sources.filter { quality == "All" || $0.quality == quality }
        let grouped = Dictionary(grouping: shown, by: \.quality)
        return grouped.keys.sorted { lhs, rhs in
            let a = StreamSource.qualityOrder.firstIndex(of: lhs) ?? 99, b = StreamSource.qualityOrder.firstIndex(of: rhs) ?? 99
            return a == b ? lhs < rhs : a < b
        }.map { ($0, sorted(grouped[$0] ?? [])) }
    }

    private func sorted(_ sources: [StreamSource]) -> [StreamSource] {
        switch order {
        case .best: return SourceRanker.rank(sources, memory: memory) + sources.filter { !$0.isPlayable }
        case .largest: return cachedFirst(sources.sorted { $0.sizeBytes > $1.sizeBytes })
        case .smallest: return cachedFirst(sources.sorted { ($0.sizeBytes == 0 ? .infinity : $0.sizeBytes) < ($1.sizeBytes == 0 ? .infinity : $1.sizeBytes) })
        case .seeders: return cachedFirst(sources.sorted { ($0.seeders ?? 0) > ($1.seeders ?? 0) })
        }
    }

    private func cachedFirst(_ sources: [StreamSource]) -> [StreamSource] {
        sources.filter(\.isCached) + sources.filter { !$0.isCached }
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading {
                    ProgressView("Searching sources…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = model.error, model.sources.isEmpty {
                    StateMessage(title: "Couldn't load sources", message: error, actionTitle: "Retry") {
                        Task { await model.load(target, playback: playback, query: settings.sourceQuery, refresh: true) }
                    }
                } else if model.sources.isEmpty {
                    StateMessage(title: "No sources", message: "Nothing was found with your current filters and addons.", systemImage: "tray")
                } else {
                    list
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
                        Button("Refresh", systemImage: "arrow.clockwise") {
                            Task { await model.load(target, playback: playback, query: settings.sourceQuery, refresh: true) }
                        }
                    } label: {
                        Label("Sort and filter", systemImage: "line.3.horizontal.decrease")
                    }
                }
            }
        }
        .task { await model.load(target, playback: playback, query: settings.sourceQuery) }
    }

    private var list: some View {
        List {
            if !settings.isDebridConfigured {
                Label("Add a debrid service in Settings to play Torrentio's sources.", systemImage: "info.circle")
                    .foregroundStyle(Theme.secondaryText)
            }
            if let pick = recommended, quality == "All", order == .best {
                Section {
                    sourceButton(pick)
                } header: {
                    Label("Recommended", systemImage: "sparkles")
                } footer: {
                    Text("What Play picks: instant first, then your quality order, then what has played well for you before.")
                }
            }
            ForEach(groups, id: \.0) { group in
                Section("\(group.0) · \(group.1.count)") {
                    ForEach(group.1) { source in sourceButton(source) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .refreshable { await model.load(target, playback: playback, query: settings.sourceQuery, refresh: true) }
    }

    private func sourceButton(_ source: StreamSource) -> some View {
        Button {
            playback.play(target, settings: settings, library: library, source: source, fromStart: playback.chooseFromStart)
            dismiss()
        } label: {
            SourceRow(
                source: source,
                history: memory.failedBefore(source) ? .failed : (memory.playedWell(source) ? .good : nil),
                verification: memory.verification(for: source),
                verifying: model.verifying.contains(source.fileKey),
                verifyError: model.verifyErrors[source.fileKey]
            )
        }
        .buttonStyle(.plain)
        .disabled(!source.isPlayable)
        .swipeActions(edge: .trailing) {
            if source.isCached {
                Button { model.verify(source, playback: playback) } label: { Label("Check", systemImage: "checkmark.seal") }
                    .tint(.indigo)
            }
        }
        .contextMenu {
            Button { playback.play(target, settings: settings, library: library, source: source, fromStart: playback.chooseFromStart); dismiss() } label: {
                Label("Play", systemImage: "play.fill")
            }
            if source.isCached {
                Button { model.verify(source, playback: playback) } label: {
                    Label("Check Format", systemImage: "checkmark.seal")
                }
                Button { playback.download(target, settings: settings, source: source) } label: {
                    Label(downloads.item(for: target) == nil ? "Download" : "Download This Instead", systemImage: "arrow.down.circle")
                }
            }
        }
    }
}

struct SourceRow: View {
    enum History { case good, failed }

    let source: StreamSource
    var history: History?
    var verification: SourceVerification?
    var verifying = false
    var verifyError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                QualityBadge(quality: source.quality)
                ForEach(shownTags, id: \.self) { tag in
                    Text(tag).font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                Spacer(minLength: 4)
                if source.debridTag != nil || source.isCached {
                    Label(source.isCached ? "Instant" : "Download", systemImage: source.isCached ? "bolt.fill" : "arrow.down.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(source.isCached ? Theme.cached : Theme.secondaryText)
                        .accessibilityLabel(source.debridTag ?? "Instant")
                }
            }
            Text(source.release).font(.subheadline.weight(.medium)).lineLimit(2)
            if let file = source.file, file != source.release {
                Text(file).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
            }
            verificationLine
            HStack(spacing: 14) {
                if let size = source.size { Label(size, systemImage: "internaldrive") }
                if let seeders = source.seeders { Label("\(seeders)", systemImage: "person.2.fill") }
                if source.addon != "Torrentio" { Label(source.addon, systemImage: "puzzlepiece.extension") }
                else if let provider = source.provider { Label(provider, systemImage: "globe") }
                if let languages = source.languages { Text(languages).lineLimit(1) }
            }
            .font(.caption)
            .foregroundStyle(Theme.secondaryText)
            if let history {
                Label(history == .good ? "Played well before" : "Failed to play before",
                      systemImage: history == .good ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(history == .good ? Theme.cached : .orange)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .opacity(source.isPlayable ? 1 : 0.5)
    }

    /// Once the file has been checked, its real format replaces the release name's claims.
    private var shownTags: [String] {
        let claimed = Array(source.tags.prefix(4))
        guard verification != nil else { return claimed }
        return claimed.filter { !["DV", "HDR", "HDR10", "HDR10+", "HLG", "Atmos"].contains($0) }
    }

    @ViewBuilder private var verificationLine: some View {
        if verifying {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Checking the file…").font(.caption)
            }
            .foregroundStyle(Theme.secondaryText)
        } else if let verification {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.accent)
                ForEach(verification.badges.isEmpty ? ["SDR"] : verification.badges, id: \.self) { badge in
                    Text(badge).font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                if let detail = [verification.resolution, verification.audio].compactMap({ $0 }).joined(separator: " · ").nilIfEmpty {
                    Text(detail).font(.caption2).foregroundStyle(Theme.secondaryText).lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Checked: \(verification.badges.joined(separator: ", "))")
        } else if let verifyError {
            Label(verifyError, systemImage: "xmark.seal").font(.caption).foregroundStyle(.orange).lineLimit(2)
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
