import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// What the app hands its widgets: Continue Watching and the next episodes, written into the
/// app group's container. Pictures are saved beside it, small, so a widget never waits on the
/// network.
struct WidgetData: Codable, Equatable {
    struct Entry: Codable, Equatable, Identifiable {
        let id: String
        let title: String
        let subtitle: String
        /// Watched so far, 0...1; nil for an episode that hasn't been started.
        let fraction: Double?
        /// File name of the picture in the container.
        let image: String?
        /// Where tapping it goes.
        let link: URL
    }

    var continueWatching: [Entry] = []
    var upcoming: [Entry] = []
    var updatedAt = Date()

    static let appGroup = "group.community.reel.app"

    /// The shared folder, or nil when the app group isn't granted (a build signed without it).
    static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("Widgets", isDirectory: true)
    }

    static func load() -> WidgetData? {
        guard let url = folder?.appendingPathComponent("widgets.json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetData.self, from: data)
    }

    static func imageURL(_ name: String?) -> URL? {
        guard let name else { return nil }
        return folder?.appendingPathComponent(name)
    }
}

#if canImport(ActivityKit)
/// A download as a Live Activity: on the Lock Screen and in the Dynamic Island while it runs.
struct DownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var fraction: Double
        var detail: String
        var finished: Bool
    }

    var title: String
}
#endif
