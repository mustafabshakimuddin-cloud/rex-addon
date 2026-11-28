import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The app's JSON files in Application Support. A file that exists but can't be decoded is moved
/// aside rather than read as empty: an empty store would overwrite it on its next save, and the
/// user's library would be gone.
enum JSONFile {
    static let folder: URL = {
        #if os(tvOS)
        // Apple TV gives apps no lasting storage of their own: Caches is kept unless the device
        // runs short of space, which is the most it offers. Back Up and Trakt guard the rest.
        let base = FileManager.SearchPathDirectory.cachesDirectory
        #else
        let base = FileManager.SearchPathDirectory.applicationSupportDirectory
        #endif
        let folder = (try? FileManager.default.url(for: base, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return folder
    }()

    static func url(_ name: String) -> URL { folder.appendingPathComponent(name) }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var moved: [String] = []

    /// Files moved aside this launch because they couldn't be read, by name.
    static var unreadableFiles: [String] {
        lock.lock(); defer { lock.unlock() }
        return moved
    }

    /// The decoded file, or nil when there is none. An unreadable file is renamed
    /// `name.unreadable-<date>.json` and kept, so nothing is lost and it can be recovered by hand.
    static func read<T: Decodable>(_ type: T.Type, from url: URL, decoder: JSONDecoder = JSONDecoder()) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            quarantine(url)
            return nil
        }
    }

    static func quarantine(_ url: URL) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let destination = url.deletingPathExtension().appendingPathExtension("unreadable-\(stamp).json")
        try? FileManager.default.moveItem(at: url, to: destination)
        lock.lock(); moved.append(url.lastPathComponent); lock.unlock()
    }
}

/// Decodes what it can: one malformed element costs that element, not the whole list.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension KeyedDecodingContainer {
    /// An array whose unreadable elements are dropped.
    func lossyArray<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T] {
        ((try? decodeIfPresent([Lossy<T>].self, forKey: key)) ?? nil)?.compactMap(\.value) ?? []
    }

    /// A dictionary whose unreadable values are dropped.
    func lossyDictionary<T: Decodable>(_ type: T.Type, forKey key: Key) -> [String: T] {
        let raw = ((try? decodeIfPresent([String: Lossy<T>].self, forKey: key)) ?? nil) ?? [:]
        return raw.compactMapValues(\.value)
    }
}

/// Writes a store's snapshot after a pause, so a burst of changes costs one write. Encoding and
/// writing happen on a serial queue, off the main thread, in order; a snapshot overtaken by a
/// newer one is skipped.
final class SnapshotWriter: @unchecked Sendable {
    private let url: URL
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var generation = 0
    private var pending: DispatchWorkItem?

    init(url: URL) {
        self.url = url
        queue = DispatchQueue(label: "community.reel.save.\(url.lastPathComponent)", qos: .utility)
    }

    func schedule(after seconds: Double, _ encode: @escaping @Sendable () -> Data?) {
        enqueue(after: seconds, encode: encode, finished: nil)
    }

    /// Writes now (still off the main thread). On iOS the app asks for background time so the
    /// write finishes even when this runs on the way into the background.
    func flush(_ encode: @escaping @Sendable () -> Data?) {
        #if canImport(UIKit)
        let done = BackgroundTime.begin("Save \(url.lastPathComponent)")
        enqueue(after: 0, encode: encode, finished: done)
        #else
        enqueue(after: 0, encode: encode, finished: nil)
        #endif
    }

    /// Blocks until every queued write has finished. For tests.
    func waitUntilWritten() {
        queue.sync {}
    }

    private func enqueue(after seconds: Double, encode: @escaping @Sendable () -> Data?, finished: (@Sendable () -> Void)?) {
        lock.lock()
        generation += 1
        let mine = generation
        pending?.cancel()
        let url = url
        let item = DispatchWorkItem { [weak self] in
            defer { finished?() }
            guard let self, self.isCurrent(mine), let data = encode() else { return }
            try? data.write(to: url, options: .atomic)
        }
        pending = item
        lock.unlock()
        if seconds > 0 { queue.asyncAfter(deadline: .now() + seconds, execute: item) } else { queue.async(execute: item) }
        // A cancelled item never runs, so release its background time here too.
        if let finished { item.notify(queue: queue) { if item.isCancelled { finished() } } }
    }

    private func isCurrent(_ value: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return value == generation
    }
}

#if canImport(UIKit)
/// A background task assertion that ends itself once, from any thread.
enum BackgroundTime {
    static func begin(_ name: String) -> @Sendable () -> Void {
        let box = TaskBox()
        let start = {
            box.id = UIApplication.shared.beginBackgroundTask(withName: name) { box.end() }
        }
        if Thread.isMainThread { MainActor.assumeIsolated { start() } } else { DispatchQueue.main.sync { start() } }
        return { box.end() }
    }

    private final class TaskBox: @unchecked Sendable {
        var id: UIBackgroundTaskIdentifier = .invalid
        private let lock = NSLock()
        private var ended = false

        func end() {
            lock.lock()
            guard !ended else { lock.unlock(); return }
            ended = true
            lock.unlock()
            DispatchQueue.main.async { [id] in
                if id != .invalid { UIApplication.shared.endBackgroundTask(id) }
            }
        }
    }
}
#endif
