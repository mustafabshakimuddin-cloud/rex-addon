import Foundation
import UserNotifications
#if !os(macOS)
import BackgroundTasks
#endif
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Local notifications: a download that finished while the app was away, and new episodes of the
/// series you follow. Episodes are scheduled ahead for when they air, so they arrive on time even
/// if the system never wakes the app; a background refresh a few times a day keeps the schedule
/// current.
@MainActor
enum Notifier {
    static let refreshTask = "community.reel.app.refresh"
    private static let scheduledPrefix = "episode:"

    /// Asks once; afterwards iOS remembers the answer.
    static func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied: return false
        default:
            #if os(tvOS)
            // Apple TV shows no notification banners; the count of new episodes goes on the icon.
            return (try? await center.requestAuthorization(options: [.badge])) ?? false
            #else
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            #endif
        }
    }

    /// The number on the app's icon: on Apple TV, where there are no banners, the new episodes
    /// waiting and the setup that stops anything playing.
    static func setBadge(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(count) { _ in }
    }

    static func downloadFinished(_ item: DownloadItem) {
        #if !os(tvOS)
        #if os(macOS)
        guard !NSApplication.shared.isActive else { return }
        #else
        guard UIApplication.shared.applicationState != .active else { return }
        #endif
        let content = UNMutableNotificationContent()
        content.title = "Downloaded"
        content.body = "\(item.target.displayTitle) is ready to watch offline."
        content.sound = .default
        content.userInfo = ["title": item.target.item.id, "kind": item.target.item.kind.rawValue]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "download:\(item.id)", content: content, trigger: nil))
        #endif
    }

    /// Replaces the scheduled episode notifications with one for each episode of a followed series
    /// that airs in the next two weeks.
    static func scheduleEpisodes(_ episodes: [CalendarEpisode]) async {
        #if !os(tvOS)
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(scheduledPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        let now = Date()
        let soon = episodes.filter { $0.date > now && $0.date < now.addingTimeInterval(14 * 86_400) }.prefix(50)
        for episode in soon {
            let content = UNMutableNotificationContent()
            content.title = episode.item.name
            content.body = "\(episode.episode.code) · \(episode.episode.title) is out."
            content.sound = .default
            content.userInfo = ["title": episode.item.id, "kind": MediaKind.series.rawValue]
            let trigger = UNCalendarNotificationTrigger(dateMatching: fireDate(for: episode.date), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: scheduledPrefix + episode.id, content: content, trigger: trigger))
        }
        #endif
    }

    static func cancelEpisodes() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(scheduledPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
    }

    /// Cinemeta gives many air dates as midnight UTC, which isn't when anything is out; those are
    /// announced at 9 in the morning, local time, on that day.
    static func fireDate(for date: Date) -> DateComponents {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .current
        let parts = utc.dateComponents([.hour, .minute], from: date)
        if parts.hour == 0 && parts.minute == 0 {
            var day = utc.dateComponents([.year, .month, .day], from: date)
            day.hour = 9
            day.calendar = Calendar.current
            day.timeZone = .current
            return day
        }
        return Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }

    /// Asks iOS to wake the app in a few hours to refresh the calendar.
    static func scheduleRefresh() {
        #if os(macOS)
        // The Mac has no app refresh; while the app runs, Calendar refreshes itself, and the
        // episodes already scheduled arrive whether it runs or not.
        #else
        let request = BGAppRefreshTaskRequest(identifier: refreshTask)
        request.earliestBeginDate = Date().addingTimeInterval(4 * 3600)
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }
}
