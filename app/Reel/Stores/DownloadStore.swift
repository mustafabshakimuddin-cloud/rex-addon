import Foundation
import Combine
import UIKit

/// One title saved for offline viewing.
struct DownloadItem: Codable, Identifiable, Hashable {
    enum State: Codable, Hashable {
        case downloading, paused, finished, failed(String)
    }

    var id: String { target.videoID }
    var target: PlaybackTarget
    var source: StreamSource
    var remoteURL: URL
    var state: State
    var written: Int64 = 0
    var expected: Int64 = 0
    var fileName: String?
    var createdAt = Date()

    var fraction: Double { expected > 0 ? min(1, Double(written) / Double(expected)) : 0 }
    var isFinished: Bool { state == .finished }
}

/// Downloads into Application Support with a background URLSession, so a film keeps coming down
/// while the app is closed. Files are excluded from iCloud backup: they are large and can be
/// downloaded again.
@MainActor
final class DownloadStore: ObservableObject {
    static let sessionIdentifier = "community.reel.app.downloads"

    @Published private(set) var items: [String: DownloadItem] = [:]

    /// Handed over by the app delegate when the system relaunches the app for finished transfers.
    var backgroundCompletion: (() -> Void)?

    private let folder: URL
    private let indexURL: URL
    private let relay: DownloadRelay
    private let session: URLSession
    private var lastPublished: [String: Date] = [:]

    init() {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        var folder = support.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        self.folder = folder
        indexURL = support.appendingPathComponent("downloads.json")

        let relay = DownloadRelay(folder: folder)
        self.relay = relay
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.allowsCellularAccess = true
        session = URLSession(configuration: configuration, delegate: relay, delegateQueue: nil)
        relay.store = self

        if let data = try? Data(contentsOf: indexURL), let saved = try? JSONDecoder().decode([String: DownloadItem].self, from: data) {
            items = saved
        }
        reconcile()
    }

    var ordered: [DownloadItem] { items.values.sorted { $0.createdAt > $1.createdAt } }

    func item(for target: PlaybackTarget) -> DownloadItem? { items[target.videoID] }

    /// The local copy of a title, when one has finished downloading.
    func completedFile(for target: PlaybackTarget) -> (url: URL, source: StreamSource)? {
        guard let item = items[target.videoID], item.isFinished, let name = item.fileName else { return nil }
        let url = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return (url, item.source)
    }

    func start(_ target: PlaybackTarget, source: StreamSource, url: URL) {
        if let existing = items[target.videoID], existing.state == .downloading { return }
        let item = DownloadItem(target: target, source: source, remoteURL: url, state: .downloading)
        items[target.videoID] = item
        let task = session.downloadTask(with: url)
        task.taskDescription = target.videoID
        task.resume()
        save()
    }

    func pause(_ item: DownloadItem) {
        session.getAllTasks { tasks in
            for task in tasks where task.taskDescription == item.id {
                (task as? URLSessionDownloadTask)?.cancel { data in
                    Task { @MainActor in
                        self.relay.storeResumeData(data, for: item.id)
                        self.update(item.id) { $0.state = .paused }
                    }
                }
            }
        }
    }

    func resume(_ item: DownloadItem) {
        let task: URLSessionDownloadTask
        if let data = relay.takeResumeData(for: item.id) {
            task = session.downloadTask(withResumeData: data)
        } else {
            task = session.downloadTask(with: item.remoteURL)
        }
        task.taskDescription = item.id
        task.resume()
        update(item.id) { $0.state = .downloading }
    }

    func delete(_ item: DownloadItem) {
        session.getAllTasks { tasks in
            for task in tasks where task.taskDescription == item.id { task.cancel() }
        }
        if let name = item.fileName { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
        _ = relay.takeResumeData(for: item.id)
        items[item.id] = nil
        save()
    }

    var usedBytes: Int64 {
        items.values.compactMap { item -> Int64? in
            guard let name = item.fileName else { return nil }
            let attributes = try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)
            return (attributes?[.size] as? NSNumber)?.int64Value
        }.reduce(0, +)
    }

    var freeBytes: Int64? {
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: From the session

    fileprivate func progressed(_ id: String, written: Int64, expected: Int64) {
        // Progress arrives many times a second; the list needs about one update a second.
        let now = Date()
        if let last = lastPublished[id], now.timeIntervalSince(last) < 0.8 { return }
        lastPublished[id] = now
        update(id, persist: false) {
            $0.written = written
            if expected > 0 { $0.expected = expected }
            if $0.state != .downloading { $0.state = .downloading }
        }
    }

    fileprivate func finished(_ id: String, fileName: String) {
        update(id) {
            $0.fileName = fileName
            $0.state = .finished
            $0.written = max($0.written, $0.expected)
        }
    }

    fileprivate func failed(_ id: String, message: String, canResume: Bool) {
        update(id) { $0.state = canResume ? .paused : .failed(message) }
    }

    fileprivate func finishBackgroundEvents() {
        // The system may wake the app for this without ever making a scene active, so the handler
        // can still be parked on the app delegate.
        let completion = backgroundCompletion ?? AppDelegate.pendingBackgroundCompletion
        backgroundCompletion = nil
        AppDelegate.pendingBackgroundCompletion = nil
        completion?()
    }

    private func update(_ id: String, persist: Bool = true, _ change: (inout DownloadItem) -> Void) {
        guard var item = items[id] else { return }
        change(&item)
        items[id] = item
        if persist { save() }
    }

    /// After a relaunch: anything the index says is downloading but the session no longer runs was
    /// interrupted, and can be resumed by hand.
    private func reconcile() {
        session.getAllTasks { tasks in
            let running = Set(tasks.compactMap(\.taskDescription))
            Task { @MainActor in
                for (id, item) in self.items where item.state == .downloading && !running.contains(id) {
                    self.update(id) { $0.state = .paused }
                }
            }
        }
    }

    private func save() {
        let snapshot = items
        let url = indexURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }
}

/// The session's delegate. URLSession calls it on its own queue, and the downloaded file must be
/// moved before `didFinishDownloadingTo` returns, so the move happens here and only the result
/// goes to the main actor.
private final class DownloadRelay: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    weak var store: DownloadStore?
    private let folder: URL
    private let lock = NSLock()

    init(folder: URL) { self.folder = folder }

    private func resumeURL(for id: String) -> URL {
        folder.appendingPathComponent(".\(Self.safeName(id)).resume")
    }

    func storeResumeData(_ data: Data?, for id: String) {
        guard let data else { return }
        try? data.write(to: resumeURL(for: id), options: .atomic)
    }

    func takeResumeData(for id: String) -> Data? {
        let url = resumeURL(for: id)
        defer { try? FileManager.default.removeItem(at: url) }
        return try? Data(contentsOf: url)
    }

    static func safeName(_ id: String) -> String {
        id.map { $0.isLetter || $0.isNumber ? $0 : "_" }.map(String.init).joined()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        let store = self.store; Task { @MainActor in store?.progressed(id, written: totalBytesWritten, expected: totalBytesExpectedToWrite) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let store = self.store; Task { @MainActor in store?.failed(id, message: "The server answered \(http.statusCode).", canResume: false) }
            return
        }
        let remote = downloadTask.originalRequest?.url
        var ext = remote?.pathExtension.lowercased() ?? ""
        if !["mkv", "mp4", "m4v", "avi", "ts", "webm", "mov"].contains(ext) { ext = "mkv" }
        let name = "\(Self.safeName(id)).\(ext)"
        let destination = folder.appendingPathComponent(name)
        let store = self.store
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            Task { @MainActor in store?.finished(id, fileName: name) }
        } catch {
            let message = error.localizedDescription
            Task { @MainActor in store?.failed(id, message: message, canResume: false) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return }
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled && nsError.userInfo[NSURLSessionDownloadTaskResumeData] == nil { return }
        let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        storeResumeData(resumeData, for: id)
        let message = error.localizedDescription
        let canResume = resumeData != nil
        let store = self.store; Task { @MainActor in
            store?.failed(id, message: message, canResume: canResume)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let store = self.store; Task { @MainActor in store?.finishBackgroundEvents() }
    }
}
