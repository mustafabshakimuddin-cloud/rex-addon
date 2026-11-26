import SwiftUI

/// What you've watched, newest first and grouped by day: Today, Yesterday, then dates.
struct HistoryView: View {
    @Environment(Library.self) private var library
    @Environment(PlaybackCenter.self) private var playback
    @Environment(AppSettings.self) private var settings
    @State private var filter: LibraryFilter = .all
    @State private var confirmClear = false

    private struct Day: Identifiable {
        let date: Date
        let entries: [PlaybackProgress]
        var id: Date { date }
    }

    private var days: [Day] {
        let calendar = Calendar.current
        let entries = library.history.filter { entry in
            switch filter {
            case .all: return true
            case .movies: return entry.item.kind == .movie
            case .series: return entry.item.kind == .series
            case .unwatched: return !entry.isFinished
            }
        }
        let grouped = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.updatedAt) }
        return grouped.keys.sorted(by: >).map { Day(date: $0, entries: grouped[$0] ?? []) }
    }

    var body: some View {
        List {
            if library.history.isEmpty {
                StateMessage(title: "No history yet", message: "Films and episodes you play show up here, by day.", systemImage: "clock")
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    Picker("Show", selection: $filter) {
                        ForEach(LibraryFilter.allCases) { option in
                            Text((option == .unwatched ? "Unfinished" : option.title).localized).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                ForEach(days) { day in
                    Section(header(for: day.date)) {
                        ForEach(day.entries) { entry in row(entry) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.Backdrop())
        .navigationTitle("History")
        .toolbar {
            if !library.history.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear", role: .destructive) { confirmClear = true }
                }
            }
        }
        .confirmationDialog("Clear your watch history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { library.clearHistory() }
        } message: {
            Text("Resume points and watched marks on this device are removed. Trakt keeps its own history.")
        }
    }

    private func header(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let week = calendar.date(byAdding: .day, value: -6, to: Date()), date > week {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(date: .complete, time: .omitted)
    }

    private func row(_ entry: PlaybackProgress) -> some View {
        Button {
            playback.play(entry.target, settings: settings, library: library, fromStart: entry.isFinished)
        } label: {
            HStack(spacing: 12) {
                RemoteImage(url: entry.episode?.thumbnail ?? entry.item.background ?? entry.item.poster, targetWidth: 100)
                    .frame(width: 96, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(alignment: .bottom) {
                        if !entry.isFinished {
                            GeometryReader { proxy in
                                Capsule().fill(Theme.accent).frame(width: proxy.size.width * entry.fraction, height: 3)
                                    .frame(maxHeight: .infinity, alignment: .bottom)
                            }
                        }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.item.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if let episode = entry.episode {
                        Text("\(episode.code) · \(episode.title)").font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
                    }
                    Text(status(entry)).font(.caption2).foregroundStyle(entry.isFinished ? Theme.cached : Theme.secondaryText)
                }
                Spacer(minLength: 4)
                Text(entry.updatedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption2).foregroundStyle(Theme.secondaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Theme.surface)
        .swipeActions {
            Button(role: .destructive) { library.clearProgress(entry) } label: { Label("Remove", systemImage: "trash") }
        }
        .contextMenu {
            NavigationLink(value: entry.item) { Label("Go to Title", systemImage: "info.circle") }
            if entry.isFinished {
                Button { library.markUnwatched(entry.target) } label: { Label("Mark as Unwatched", systemImage: "circle") }
            } else {
                Button { library.markWatched(entry.target) } label: { Label("Mark as Watched", systemImage: "checkmark.circle") }
            }
            Button(role: .destructive) { library.clearProgress(entry) } label: { Label("Remove from History", systemImage: "trash") }
        }
    }

    private func status(_ entry: PlaybackProgress) -> String {
        if entry.isFinished { return "Finished" }
        let minutes = Int(max(0, entry.duration - entry.position) / 60)
        let left = minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m left" : "\(minutes)m left"
        return "\(Int(entry.fraction * 100))% · \(left)"
    }
}
