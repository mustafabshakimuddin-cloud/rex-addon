import Foundation
import UIKit
import WidgetKit
import ActivityKit

/// Writes what the widgets show into the app group, with small pictures, and asks WidgetKit to
/// redraw. Does nothing when the app group isn't granted.
@MainActor
enum WidgetPublisher {
    private static var lastWritten: WidgetData?

    static func publish(library: Library, upcoming: UpcomingStore) async {
        guard let folder = WidgetData.folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var keep = Set<String>()

        var continuing: [WidgetData.Entry] = []
        for entry in library.continueWatching.prefix(6) {
            let image = await picture(entry.episode?.thumbnail ?? entry.item.background ?? entry.item.poster,
                                      name: "cw-\(safe(entry.id))", in: folder)
            if let image { keep.insert(image) }
            let left = max(0, entry.duration - entry.position)
            var subtitle = entry.episode.map { "\($0.code) · " } ?? ""
            subtitle += entry.isUpNext ? "Next episode" : (left >= 3600 ? "\(Int(left / 3600))h \(Int(left.truncatingRemainder(dividingBy: 3600) / 60))m left" : "\(Int(left / 60))m left")
            continuing.append(.init(id: entry.id, title: entry.item.name, subtitle: subtitle,
                                    fraction: entry.isUpNext ? nil : entry.fraction, image: image,
                                    link: URL(string: "reel://resume/\(entry.id)?type=\(entry.item.kind.rawValue)")!))
        }

        var coming: [WidgetData.Entry] = []
        var seen = Set<String>()
        for episode in upcoming.upcoming where seen.insert(episode.item.id).inserted {
            guard coming.count < 5 else { break }
            let image = await picture(episode.item.background ?? episode.item.poster, name: "up-\(safe(episode.item.id))", in: folder)
            if let image { keep.insert(image) }
            let when = episode.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            coming.append(.init(id: episode.id, title: episode.item.name, subtitle: "\(episode.episode.code) · \(when)",
                                fraction: nil, image: image,
                                link: URL(string: "reel://title/\(episode.item.id)?type=series")!))
        }

        var data = WidgetData(continueWatching: continuing, upcoming: coming)
        data.updatedAt = lastWritten?.updatedAt ?? Date()
        guard data != lastWritten else { return }
        data.updatedAt = Date()
        if let encoded = try? JSONEncoder().encode(data) {
            try? encoded.write(to: folder.appendingPathComponent("widgets.json"), options: .atomic)
        }
        lastWritten = data
        // Pictures of titles no longer shown go.
        for file in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        where file.hasSuffix(".jpg") && !keep.contains(file) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func picture(_ url: URL?, name: String, in folder: URL) async -> String? {
        guard let url else { return nil }
        let file = "\(name).jpg"
        let path = folder.appendingPathComponent(file)
        if FileManager.default.fileExists(atPath: path.path) { return file }
        guard let image = await ImageLoader.shared.image(for: url, maxPixelSize: 400),
              let data = image.jpegData(compressionQuality: 0.7),
              (try? data.write(to: path, options: .atomic)) != nil else { return nil }
        return file
    }

    private static func safe(_ id: String) -> String {
        id.map { $0.isLetter || $0.isNumber ? $0 : "_" }.map(String.init).joined()
    }
}

/// A Live Activity per running download, updated every few seconds.
@MainActor
final class DownloadActivities {
    private var activities: [String: Activity<DownloadActivityAttributes>] = [:]
    private var lastUpdate: [String: Date] = [:]

    func progress(_ item: DownloadItem, speed: Double?) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        var detail = item.expected > 0
            ? "\(ByteCountFormatter.string(fromByteCount: item.written, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: item.expected, countStyle: .file))"
            : "Starting…"
        if let speed, speed > 0 { detail += " · \(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file))/s" }
        let state = DownloadActivityAttributes.ContentState(fraction: item.fraction, detail: detail, finished: false)
        if let activity = activities[item.id] {
            if let last = lastUpdate[item.id], Date().timeIntervalSince(last) < 5 { return }
            lastUpdate[item.id] = Date()
            // ActivityKit's handle isn't marked Sendable, though its methods are safe from any task.
            nonisolated(unsafe) let handle = activity
            Task { await handle.update(ActivityContent(state: state, staleDate: nil)) }
        } else if let activity = try? Activity.request(attributes: DownloadActivityAttributes(title: item.target.displayTitle),
                                                       content: ActivityContent(state: state, staleDate: nil)) {
            activities[item.id] = activity
            lastUpdate[item.id] = Date()
        }
    }

    func end(_ item: DownloadItem, finished: Bool) {
        guard let activity = activities.removeValue(forKey: item.id) else { return }
        lastUpdate[item.id] = nil
        let state = DownloadActivityAttributes.ContentState(fraction: finished ? 1 : item.fraction,
                                                            detail: finished ? "Ready to watch offline" : "Stopped", finished: finished)
        nonisolated(unsafe) let handle = activity
        let dismissal = Date().addingTimeInterval(finished ? 900 : 60)
        Task { await handle.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(dismissal)) }
    }
}
