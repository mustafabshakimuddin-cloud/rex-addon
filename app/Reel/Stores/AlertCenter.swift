import Foundation
import Combine

/// Something worth telling you about: a download that finished or failed, a sync that broke.
struct AppAlert: Identifiable, Codable, Hashable {
    enum Level: String, Codable { case info, success, warning, problem }
    enum Action: String, Codable { case openDownloads, openStatus, openTrakt, openSetup }

    var id = UUID()
    var title: String
    var message: String?
    var level: Level
    var action: Action?
    var date = Date()

    var systemImage: String {
        switch level {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .problem: return "xmark.octagon.fill"
        }
    }

    var actionTitle: String? {
        switch action {
        case .openDownloads?: return "Downloads"
        case .openStatus?: return "Status"
        case .openTrakt?: return "Trakt"
        case .openSetup?: return "Set Up"
        case nil: return nil
        }
    }
}

/// Pop-ups and the list of recent alerts under Settings → Status. A pop-up shows for a few seconds
/// over whatever is on screen; the list keeps the last few dozen across launches.
@MainActor
final class AlertCenter: ObservableObject {
    @Published private(set) var current: AppAlert?
    @Published private(set) var recent: [AppAlert] = []
    /// Alerts not yet seen in the list; Settings shows a red dot while there are problems among them.
    @Published private(set) var unseenProblems = 0

    private let defaults = UserDefaults.standard
    private var dismissTask: Task<Void, Never>?
    private var queue: [AppAlert] = []
    private static let key = "alerts.recent"
    private static let keep = 40

    init() {
        if let data = defaults.data(forKey: Self.key), let saved = try? JSONDecoder().decode([AppAlert].self, from: data) {
            recent = saved
        }
    }

    func post(_ title: String, message: String? = nil, level: AppAlert.Level = .info, action: AppAlert.Action? = nil,
              popUp: Bool = true) {
        let alert = AppAlert(title: title, message: message, level: level, action: action)
        // The same problem reported again within a minute (a sync retried) is one alert, not two.
        if let last = recent.first, last.title == alert.title, last.message == alert.message,
           alert.date.timeIntervalSince(last.date) < 60 {
            return
        }
        recent.insert(alert, at: 0)
        if recent.count > Self.keep { recent.removeLast(recent.count - Self.keep) }
        if alert.level == .problem || alert.level == .warning { unseenProblems += 1 }
        save()
        guard popUp else { return }
        if current == nil { show(alert) } else { queue.append(alert) }
    }

    func dismissCurrent() {
        dismissTask?.cancel()
        current = nil
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            self.show(next)
        }
    }

    func markSeen() { unseenProblems = 0 }

    func clear() {
        recent = []
        unseenProblems = 0
        save()
    }

    private func show(_ alert: AppAlert) {
        current = alert
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: alert.level == .problem ? 6_000_000_000 : 4_000_000_000)
            guard !Task.isCancelled, self.current?.id == alert.id else { return }
            self.dismissCurrent()
        }
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(recent), forKey: Self.key)
    }
}
