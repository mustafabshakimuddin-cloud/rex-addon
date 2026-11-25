import Foundation
import os

/// A short record of what went wrong recently, for Settings → Status and the report shared when
/// asking for help. Lines are redacted before they are kept: no debrid key or token ever lands
/// here. Also written to the system log under the app's subsystem.
enum AppLog {
    struct Entry: Codable, Hashable, Identifiable {
        var id = UUID()
        var date = Date()
        var area: String
        var message: String
    }

    private static let logger = Logger(subsystem: "community.reel.app", category: "events")
    private static let lock = NSLock()
    private static let key = "log.entries"
    private static let keep = 80
    nonisolated(unsafe) private static var cached: [Entry]?

    static func record(_ area: String, _ message: String) {
        let clean = Redact.text(message)
        logger.error("\(area, privacy: .public): \(clean, privacy: .public)")
        lock.lock()
        var list = loadLocked()
        list.insert(Entry(area: area, message: clean), at: 0)
        if list.count > keep { list.removeLast(list.count - keep) }
        cached = list
        lock.unlock()
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: key)
    }

    static func record(_ area: String, _ error: Error) {
        record(area, error.localizedDescription)
    }

    static var entries: [Entry] {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()
    }

    static func clear() {
        lock.lock(); cached = []; lock.unlock()
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func loadLocked() -> [Entry] {
        if let cached { return cached }
        let saved = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        cached = saved
        return saved
    }
}
