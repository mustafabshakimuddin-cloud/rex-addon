import SwiftUI

@MainActor
@Observable
final class SourcesModel {
    var sources: [StreamSource] = [] { didSet { ranked = nil } }
    var isLoading = true
    var error: String?
    var verifying: Set<String> = []
    var verifyErrors: [String: String] = [:]
    /// Playable sources in Play's order, worked out once per list rather than on every redraw.
    @ObservationIgnored private(set) var ranked: [StreamSource]?

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
            self.error = PlaybackError.describe(error)
        }
    }

    func ranking(memory: SourceMemory, preferences: SourcePreferences) -> [StreamSource] {
        if let ranked { return ranked }
        let result = SourceRanker.rank(sources, memory: memory, preferences: preferences)
        ranked = result
        return result
    }

    func invalidateRanking() { ranked = nil }

    func verify(_ source: StreamSource, playback: PlaybackCenter, settings: AppSettings) {
        guard !verifying.contains(source.fileKey) else { return }
        verifying.insert(source.fileKey)
        verifyErrors[source.fileKey] = nil
        Task {
            do {
                _ = try await playback.verify(source, settings: settings)
            } catch {
                verifyErrors[source.fileKey] = PlaybackError.describe(error)
            }
            verifying.remove(source.fileKey)
        }
    }
}

/// Every release found, grouped by quality, with what matters for choosing one: what history says
/// about it, and what the file really contains once checked.
struct SourcesSheet: View {
    let target: PlaybackTarget
    @Environment(AppSettings.self) private var settings
    @Environment(Library.self) private var library
    @Environment(PlaybackCenter.self) private var playback
    @Environment(SourceMemory.self) private var memory
    @Environment(DownloadStore.self) private var downloads
    @Environment(\.dismiss) private var dismiss
    @State private var model = SourcesModel()
    @State private var quality = "All"
    @State private var order: Order = .best
    @State private var text = ""
    @State private var required: Set<String> = []
    @State private var addon: String?

    enum Order: String, CaseIterable, Identifiable {
        case best = "Best for you", largest = "Largest", smallest = "Smallest", seeders = "Most seeders"
        var id: String { rawValue }
    }

    /// Tags that can narrow the list, when at least one source carries them.
    private static let filterTags = ["Instant", "DV", "HDR", "Atmos", "Remux", "HEVC", "AV1"]

    private var qualities: [String] {
        let present = Set(model.sources.map(\.quality))
        return ["All"] + (StreamSource.qualityOrder + ["Other"]).filter(present.contains) + present.subtracting(StreamSource.qualityOrder + ["Other"]).sorted()
    }

    private var availableTags: [String] {
        Self.filterTags.filter { tag in model.sources.contains { matches($0, tag: tag) } }
    }

    private var addons: [String] { Array(Set(model.sources.map(\.addon))).sorted() }

    private var ranked: [StreamSource] { model.ranking(memory: memory, preferences: settings.sourcePreferences) }

    private var recommended: StreamSource? {
        ranked.first { $0.isCached || !settings.isDebridConfigured }
    }

    private func matches(_ source: StreamSource, tag: String) -> Bool {
        switch tag {
        case "Instant": return source.isCached
        case "HDR": return source.hasHDR
        default: return source.tags.contains(tag)
        }
    }

    private var filtered: [StreamSource] {
        let words = text.lowercased().split(separator: " ").map(String.init)
        return model.sources.filter { source in
            if quality != "All" && source.quality != quality { return false }
            if let addon, source.addon != addon { return false }
            if !required.allSatisfy({ matches(source, tag: $0) }) { return false }
            if !words.isEmpty {
                let haystack = [source.release, source.file ?? "", source.languages ?? "", source.provider ?? "",
                                source.tags.joined(separator: " "), source.releaseGroup ?? ""].joined(separator: " ").lowercased()
                if !words.allSatisfy({ haystack.contains($0) }) { return false }
            }
            return true
        }
    }

    private var isFiltering: Bool { quality != "All" || addon != nil || !required.isEmpty || !text.isEmpty }

    private var groups: [(String, [StreamSource])] {
        let shown = filtered
        let grouped = Dictionary(grouping: shown, by: \.quality)
        let rankIndex = Dictionary(ranked.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        return grouped.keys.sorted { lhs, rhs in
            let a = StreamSource.qualityOrder.firstIndex(of: lhs) ?? 99, b = StreamSource.qualityOrder.firstIndex(of: rhs) ?? 99
            return a == b ? lhs < rhs : a < b
        }.map { ($0, sorted(grouped[$0] ?? [], rankIndex: rankIndex)) }
    }

    private func sorted(_ sources: [StreamSource], rankIndex: [String: Int]) -> [StreamSource] {
        switch order {
        case .best:
            return sources.filter(\.isPlayable).sorted { (rankIndex[$0.id] ?? .max) < (rankIndex[$1.id] ?? .max) }
                + sources.filter { !$0.isPlayable }
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
            .inlineNavigationTitle()
            #if os(tvOS)
            .searchable(text: $text, prompt: "Release, group, language")
            .barActions { sortMenu }
            #else
            .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Release, group, language")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) { sortMenu }
            }
            #endif
        }
        .task { await model.load(target, playback: playback, query: settings.sourceQuery) }
        // Rules changed from the sheet's own Pick Rules page: search again with them.
        .onChange(of: settings.sourceQuery) { _, query in
            Task { await model.load(target, playback: playback, query: query) }
        }
        .onChange(of: settings.sourcePreferences) { _, _ in model.invalidateRanking() }
    }

    /// Reads the real format of the five likeliest picks, one after another.
    private func checkTop() {
        let top = ranked.filter { $0.isCached && memory.verification(for: $0) == nil }.prefix(5)
        Task {
            for source in top {
                model.verify(source, playback: playback, settings: settings)
                while model.verifying.contains(source.fileKey) { try? await Task.sleep(nanoseconds: 300_000_000) }
            }
        }
    }

    /// The rules that shaped this list, in a line, with the way to change them.
    private var rulesSummary: String {
        var parts: [String] = []
        if settings.cachedOnly && settings.isDebridConfigured { parts.append("Instant only") }
        if !settings.excludedQualities.isEmpty {
            parts.append("Hides " + settings.excludedQualities.map(SettingsView.qualityLabel).joined(separator: ", "))
        }
        if settings.maxSizeGB > 0 { parts.append("Up to \(settings.maxSizeGB) GB") }
        if !settings.providers.isEmpty { parts.append("\(settings.providers.count) providers") }
        let addons = settings.addons.filter(\.enabled).count
        if addons > 0 { parts.append("+\(addons) addon\(addons == 1 ? "" : "s")") }
        return parts.isEmpty ? "No filters" : parts.joined(separator: " · ")
    }

    private var foundSummary: String {
        let instant = model.sources.filter(\.isCached).count
        let addons = Set(model.sources.map(\.addon)).count
        var text = "\(model.sources.count) found"
        if settings.isDebridConfigured { text += " · \(instant) instant" }
        if addons > 1 { text += " · from \(addons) addons" }
        if isFiltering { text += " · \(filtered.count) shown" }
        return text
    }

    private var tagFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(availableTags, id: \.self) { tag in
                    let on = required.contains(tag)
                    Button {
                        withAnimation(.snappy) { if on { required.remove(tag) } else { required.insert(tag) } }
                    } label: {
                        Label(tag, systemImage: on ? "checkmark" : "plus").font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.glass)
                    .tint(on ? Theme.accent : nil)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
                if isFiltering {
                    Button("Clear") {
                        withAnimation(.snappy) { required = []; addon = nil; quality = "All"; text = "" }
                    }
                    .font(.caption.weight(.semibold))
                }
            }
        }
    }

    /// Sort, filters, format checks and refresh.
    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $order) {
                ForEach(Order.allCases) { Text($0.rawValue).tag($0) }
            }
            if qualities.count > 2 {
                Picker("Quality", selection: $quality) {
                    ForEach(qualities, id: \.self) { Text($0).tag($0) }
                }
            }
            if addons.count > 1 {
                Picker("Addon", selection: $addon) {
                    Text("All addons").tag(String?.none)
                    ForEach(addons, id: \.self) { Text($0).tag(String?.some($0)) }
                }
            }
            if settings.isDebridConfigured {
                Button("Check Top 5 Formats", systemImage: "checkmark.seal") { checkTop() }
            }
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await model.load(target, playback: playback, query: settings.sourceQuery, refresh: true) }
            }
        } label: {
            Label("Sort and filter", systemImage: "line.3.horizontal.decrease")
        }
    }

    private var list: some View {
        List {
            if !settings.isDebridConfigured {
                Label("Add a debrid service in Settings to play Torrentio's sources.", systemImage: "info.circle")
                    .foregroundStyle(Theme.secondaryText)
            }
            Section {
                NavigationLink {
                    PickRulesView()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Pick Rules", systemImage: "slider.horizontal.3").font(.subheadline.weight(.semibold))
                        Text(rulesSummary).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(2)
                    }
                }
                if !availableTags.isEmpty { tagFilters.listRowBackground(Color.clear) }
            } footer: {
                Text(foundSummary)
            }
            if let pick = recommended, !isFiltering, order == .best {
                Section {
                    sourceButton(pick)
                } header: {
                    Label("Recommended", systemImage: "sparkles")
                } footer: {
                    Text("What Play picks: instant first, then your quality order and source preferences, then what has played well for you before.")
                }
            }
            if filtered.isEmpty {
                Text("Nothing matches these filters.").foregroundStyle(Theme.secondaryText)
            }
            ForEach(groups, id: \.0) { group in
                Section("\(group.0) · \(group.1.count)") {
                    ForEach(group.1) { source in sourceButton(source) }
                }
            }
        }
        .groupedList()
        .clearListBackground()
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
        .cardButton()
        .disabled(!source.isPlayable)
        #if os(iOS)
        .swipeActions(edge: .trailing) {
            if source.isCached {
                Button { model.verify(source, playback: playback, settings: settings) } label: { Label("Check", systemImage: "checkmark.seal") }
                    .tint(.indigo)
            }
        }
        #endif
        .contextMenu {
            Button { playback.play(target, settings: settings, library: library, source: source, fromStart: playback.chooseFromStart); dismiss() } label: {
                Label("Play", systemImage: "play.fill")
            }
            if source.isCached {
                Button { model.verify(source, playback: playback, settings: settings) } label: {
                    Label("Check Format", systemImage: "checkmark.seal")
                }
                Button { playback.download(target, settings: settings, source: source) } label: {
                    Label(downloads.item(for: target) == nil ? "Download" : "Download This Instead", systemImage: "arrow.down.circle")
                }
            }
            if let group = source.releaseGroup {
                let favoured = settings.preferredGroups.contains { $0.caseInsensitiveCompare(group) == .orderedSame }
                Button {
                    if favoured { settings.preferredGroups.removeAll { $0.caseInsensitiveCompare(group) == .orderedSame } }
                    else { settings.preferredGroups.append(group) }
                } label: {
                    Label(favoured ? "Stop Preferring \(group)" : "Prefer \(group) Releases", systemImage: favoured ? "star.slash" : "star")
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
                ProgressView().smallControl(.mini)
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
