import SwiftUI

/// Every download in one live list: a summary of what's moving and how much room is left, then
/// each title with its progress, speed and the controls its state allows.
struct DownloadsView: View {
    @Environment(DownloadStore.self) private var downloads
    @Environment(Library.self) private var library
    @Environment(PlaybackCenter.self) private var playback
    @Environment(AppSettings.self) private var settings
    @State private var filter: Filter = .all
    @State private var confirmCleanup = false

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", active = "Active", saved = "Saved", problems = "Problems"
        var id: String { rawValue }
    }

    private var shown: [DownloadItem] {
        switch filter {
        case .all: return downloads.ordered
        case .active: return downloads.ordered.filter { $0.state == .downloading || $0.state == .paused }
        case .saved: return downloads.finished
        case .problems: return downloads.problems
        }
    }

    /// Finished downloads of things you have also finished watching.
    private var watched: [DownloadItem] { downloads.finished.filter { library.isWatched($0.target) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if downloads.items.isEmpty {
                    StateMessage(title: "No downloads",
                                 message: "Use the download button on a film, or long-press an episode, to save it for watching offline.",
                                 systemImage: "arrow.down.circle")
                        .padding(.top, 60)
                } else {
                    DownloadsSummary()
                    Picker("Show", selection: $filter.animation(.snappy)) {
                        ForEach(Filter.allCases) { option in
                            Text("\(option.rawValue) \(count(option))").tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    if shown.isEmpty {
                        Text("Nothing \(filter == .problems ? "has failed" : "here").")
                            .font(.subheadline).foregroundStyle(Theme.secondaryText)
                            .frame(maxWidth: .infinity).padding(.vertical, 30)
                    }
                    LazyVStack(spacing: 10) {
                        ForEach(shown) { item in DownloadRow(item: item) }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .readableWidth(860)
        }
        .background(Theme.Backdrop())
        .navigationTitle("Downloads")
        .barActions {
            if !downloads.items.isEmpty {
                Menu {
                    Button { downloads.pauseAll() } label: { Label("Pause All", systemImage: "pause.fill") }
                        .disabled(downloads.active.isEmpty)
                    Button { (downloads.paused + downloads.problems).forEach { playback.retryDownload($0, settings: settings) } } label: { Label("Resume All", systemImage: "arrow.down") }
                        .disabled(downloads.paused.isEmpty && downloads.problems.isEmpty)
                    Divider()
                    Button(role: .destructive) { confirmCleanup = true } label: {
                        Label("Delete Watched Downloads", systemImage: "trash")
                    }
                    .disabled(watched.isEmpty)
                } label: {
                    Label("Manage", systemImage: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Delete \(watched.count) downloads you have watched?", isPresented: $confirmCleanup, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { watched.forEach(downloads.delete) }
        } message: {
            Text("They can be downloaded again later.")
        }
    }

    private func count(_ option: Filter) -> Int {
        switch option {
        case .all: return downloads.items.count
        case .active: return downloads.active.count + downloads.paused.count
        case .saved: return downloads.finished.count
        case .problems: return downloads.problems.count
        }
    }
}

/// What's moving, how fast, and how much room is left.
struct DownloadsSummary: View {
    @Environment(DownloadStore.self) private var downloads

    var body: some View {
        let active = downloads.active
        let written = active.reduce(Int64(0)) { $0 + $1.written }
        let expected = active.reduce(Int64(0)) { $0 + $1.expected }
        let speed = active.compactMap { downloads.speeds[$0.id] }.reduce(0, +)
        let used = downloads.usedBytes
        let free = downloads.freeBytes
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(active.isEmpty ? "Nothing downloading" : (active.count == 1 ? "1 downloading" : "\(active.count) downloading"))
                        .font(.headline)
                    if !active.isEmpty, expected > 0 {
                        Text("\(bytes(written)) of \(bytes(expected))" + (speed > 0 ? " · \(bytes(Int64(speed)))/s" : ""))
                            .font(.caption).foregroundStyle(Theme.secondaryText).monospacedDigit()
                    } else {
                        Text("\(downloads.finished.count) saved for offline").font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                }
                Spacer()
                if !downloads.problems.isEmpty {
                    StatusPill(text: "\(downloads.problems.count) failed", systemImage: "exclamationmark.triangle.fill", tint: Theme.problem)
                }
            }
            if !active.isEmpty, expected > 0 {
                ProgressView(value: Double(written), total: Double(expected)).tint(Theme.accent)
            }
            if let free {
                VStack(alignment: .leading, spacing: 6) {
                    GeometryReader { proxy in
                        let total = Double(used + free)
                        Capsule().fill(Theme.surface)
                            .overlay(alignment: .leading) {
                                Capsule().fill(Theme.accentGradient)
                                    .frame(width: total > 0 ? max(6, proxy.size.width * Double(used) / total) : 0)
                            }
                    }
                    .frame(height: 8)
                    HStack {
                        Label("\(bytes(used)) downloads", systemImage: "internaldrive")
                        Spacer()
                        Text("\(bytes(free)) free")
                    }
                    .font(.caption).foregroundStyle(Theme.secondaryText)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    private func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
}

/// One download: picture, title, quality, progress and its control.
struct DownloadRow: View {
    let item: DownloadItem
    @Environment(DownloadStore.self) private var downloads
    @Environment(PlaybackCenter.self) private var playback
    @Environment(AppSettings.self) private var settings
    @Environment(Library.self) private var library

    var body: some View {
        HStack(spacing: 14) {
            RemoteImage(url: item.target.episode?.thumbnail ?? item.target.item.background ?? item.target.item.poster, targetWidth: 120)
                .frame(width: 112, height: 63)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if library.isWatched(item.target) {
                        Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(Theme.cached).padding(4)
                    }
                }
            VStack(alignment: .leading, spacing: 5) {
                Text(item.target.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    QualityBadge(quality: item.source.quality)
                    Text(status).font(.caption).foregroundStyle(statusColor).lineLimit(1).monospacedDigit()
                }
                if !item.isFinished {
                    ProgressView(value: item.fraction).tint(Theme.accent)
                }
            }
            Spacer(minLength: 4)
            control
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contextMenu {
            if item.isFinished {
                Button { playback.play(item.target, settings: settings, library: library) } label: { Label("Play", systemImage: "play.fill") }
            }
            NavigationLink(value: item.target.item) { Label("Go to Title", systemImage: "info.circle") }
            Button(role: .destructive) { downloads.delete(item) } label: { Label("Delete Download", systemImage: "trash") }
        }
    }

    @ViewBuilder private var control: some View {
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
            Button { playback.retryDownload(item, settings: settings) } label: { Image(systemName: "arrow.down").font(.headline) }
                .buttonStyle(.glass)
                .accessibilityLabel("Resume")
        case .failed:
            Button { playback.retryDownload(item, settings: settings) } label: { Image(systemName: "arrow.clockwise").font(.headline) }
                .buttonStyle(.glass)
                .accessibilityLabel("Retry")
        }
    }

    private var statusColor: Color {
        if case .failed = item.state { return Theme.problem }
        return Theme.secondaryText
    }

    private var status: String {
        switch item.state {
        case .finished:
            return item.expected > 0 ? ByteCountFormatter.string(fromByteCount: item.expected, countStyle: .file) : "Downloaded"
        case .downloading:
            guard item.expected > 0 else { return "Starting…" }
            var text = "\(Int(item.fraction * 100))% of \(ByteCountFormatter.string(fromByteCount: item.expected, countStyle: .file))"
            if let seconds = downloads.remainingSeconds(item) {
                text += " · " + Self.remaining(seconds)
            }
            return text
        case .paused: return "Paused · \(Int(item.fraction * 100))%"
        case let .failed(message): return message
        }
    }

    static func remaining(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return (formatter.string(from: seconds) ?? "") + " left"
    }
}
