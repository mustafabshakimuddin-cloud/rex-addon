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
    /// Subtitle files saved beside the video, by file name.
    var subtitleFiles: [String]?
    /// Whether the transfer may use cellular data.
    var allowsCellular: Bool?
    /// The last HTTP status the server answered, when it refused the transfer.
    var refusedStatus: Int?

    var fraction: Double { expected > 0 ? min(1, Double(written) / Double(expected)) : 0 }
    var isFinished: Bool { state == .finished }
}

enum DownloadError: LocalizedError {
    case noSpace(needed: Int64, free: Int64)

    var errorDescription: String? {
        switch self {
        case let .noSpace(needed, free):
            let fmt = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            return "This release needs \(fmt(needed)) but only \(fmt(free)) is free. Delete downloads you've watched, or pick a smaller source."
        }
    }
}

/// Downloads into Application Support with a background URLSession, so a film keeps coming down
/// while the app is closed. Files are excluded from iCloud backup: they are large and can be
/// downloaded again.
@MainActor
final class DownloadStore: ObservableObject {
    static let sessionIdentifier = "community.reel.app.downloads"

    /// What a download does beyond the file itself, read from the settings when it starts.
    struct Options {
        var allowsCellular = false
        var subtitleLanguages: [String] = []

        init(allowsCellular: Bool = false, subtitleLanguages: [String] = []) {
            self.allowsCellular = allowsCellular
            self.subtitleLanguages = subtitleLanguages
        }

        @MainActor
        init(_ settings: AppSettings) {
            allowsCellular = settings.downloadsOverCellular
            subtitleLanguages = settings.downloadSubtitles ? Languages.codes(for: settings.preferredSubtitleLanguage) : []
        }
    }

    @Published private(set) var items: [String: DownloadItem] = [:]

    /// Bytes a second for each running download, measured between progress reports.
    @Published private(set) var speeds: [String: Double] = [:]

    /// Bytes the finished and partial files take, kept up to date rather than read on each use.
    @Published private(set) var usedBytes: Int64 = 0

    enum Event { case finished(DownloadItem), failed(DownloadItem, String) }
    /// Told when a download finishes or fails, so the app can say so.
    var onEvent: ((Event) -> Void)?
    /// Told as a download moves, about once a second, with its speed: the Live Activity.
    var onProgress: ((DownloadItem, Double?) -> Void)?

    /// Handed over by the app delegate when the system relaunches the app for finished transfers.
    var backgroundCompletion: (() -> Void)?

    private let folder: URL
    private let indexURL: URL
    private let writer: SnapshotWriter
    private let relay: DownloadRelay
    private let session: URLSession
    private var lastPublished: [String: Date] = [:]
    private var subtitleLanguages: [String: [String]] = [:]

    init() {
        var folder = JSONFile.folder.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        self.folder = folder
        indexURL = JSONFile.url("downloads.json")
        writer = SnapshotWriter(url: indexURL)

        let relay = DownloadRelay(folder: folder)
        self.relay = relay
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        // Each request says whether it may use cellular; the session allows it so they can.
        configuration.allowsCellularAccess = true
        session = URLSession(configuration: configuration, delegate: relay, delegateQueue: nil)
        relay.store = self

        if let saved = JSONFile.read([String: Lossy<DownloadItem>].self, from: indexURL) {
            items = saved.compactMapValues(\.value)
        }
        recountBytes()
        reconcile()
    }

    var ordered: [DownloadItem] { items.values.sorted { $0.createdAt > $1.createdAt } }

    func item(for target: PlaybackTarget) -> DownloadItem? { items[target.videoID] }

    /// The local copy of a title, when one has finished downloading, with its subtitle files.
    func completedFile(for target: PlaybackTarget) -> (url: URL, source: StreamSource, subtitles: [URL])? {
        guard let item = items[target.videoID], item.isFinished, let name = item.fileName else { return nil }
        let url = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let subtitles = (item.subtitleFiles ?? []).map { folder.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        return (url, item.source, subtitles)
    }

    var freeBytes: Int64? {
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Refuses a release that wouldn't fit, leaving a little room for the system.
    func checkSpace(for source: StreamSource?) throws {
        guard let source, source.sizeBytes > 0, let free = freeBytes else { return }
        let needed = Int64(source.sizeBytes)
        if needed + (1 << 30) > free { throw DownloadError.noSpace(needed: needed, free: free) }
    }

    func start(_ target: PlaybackTarget, source: StreamSource, url: URL, options: Options = Options()) throws {
        if let existing = items[target.videoID] {
            if existing.state == .downloading { return }
            removeFiles(of: existing)
        }
        try checkSpace(for: source)
        var item = DownloadItem(target: target, source: source, remoteURL: url, state: .downloading)
        item.allowsCellular = options.allowsCellular
        items[target.videoID] = item
        subtitleLanguages[target.videoID] = options.subtitleLanguages
        begin(session.downloadTask(with: request(url, cellular: options.allowsCellular)), id: target.videoID)
        save()
    }

    /// Starts again from a fresh link, after the old one expired or was refused.
    func restart(_ item: DownloadItem, url: URL) {
        _ = relay.takeResumeData(for: item.id)
        update(item.id) {
            $0.remoteURL = url
            $0.state = .downloading
            $0.written = 0
            $0.refusedStatus = nil
        }
        begin(session.downloadTask(with: request(url, cellular: item.allowsCellular ?? false)), id: item.id)
    }

    func pause(_ item: DownloadItem) {
        // Marked paused at once: progress reports already queued must not flip it back.
        update(item.id) { $0.state = .paused }
        speeds[item.id] = nil
        lastPublished[item.id] = nil
        session.getAllTasks { tasks in
            for task in tasks where task.taskDescription == item.id {
                (task as? URLSessionDownloadTask)?.cancel { data in
                    Task { @MainActor in self.relay.storeResumeData(data, for: item.id) }
                }
            }
        }
    }

    /// Whether Retry can carry on where the transfer stopped, rather than needing a fresh link.
    func canResumeInPlace(_ item: DownloadItem) -> Bool {
        guard item.refusedStatus == nil else { return false }
        if relay.hasResumeData(for: item.id) { return true }
        if case .failed = item.state { return false }
        return true
    }

    func resume(_ item: DownloadItem) {
        let task: URLSessionDownloadTask
        if let data = relay.takeResumeData(for: item.id) {
            task = session.downloadTask(withResumeData: data)
        } else {
            task = session.downloadTask(with: request(item.remoteURL, cellular: item.allowsCellular ?? false))
        }
        update(item.id) { $0.state = .downloading }
        begin(task, id: item.id)
    }

    func delete(_ item: DownloadItem) {
        session.getAllTasks { tasks in
            for task in tasks where task.taskDescription == item.id { task.cancel() }
        }
        removeFiles(of: item)
        items[item.id] = nil
        save()
        recountBytes()
    }

    var active: [DownloadItem] { ordered.filter { $0.state == .downloading } }
    var paused: [DownloadItem] { ordered.filter { $0.state == .paused } }
    var finished: [DownloadItem] { ordered.filter(\.isFinished) }
    var problems: [DownloadItem] {
        ordered.filter { if case .failed = $0.state { return true } else { return false } }
    }

    func pauseAll() { active.forEach(pause) }

    /// Seconds left at the current speed, when there is one to go by.
    func remainingSeconds(_ item: DownloadItem) -> Double? {
        guard item.state == .downloading, item.expected > 0, let speed = speeds[item.id], speed > 0 else { return nil }
        return Double(item.expected - item.written) / speed
    }

    /// Deletes finished copies watched more than `days` ago. `watchedAt` gives when a title was
    /// finished, or nil while it hasn't been.
    func pruneWatched(olderThan days: Int, watchedAt: (PlaybackTarget) -> Date?) {
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for item in finished {
            if let date = watchedAt(item.target), date < cutoff { delete(item) }
        }
    }

    // MARK: From the session

    fileprivate func progressed(_ id: String, written: Int64, expected: Int64) {
        // A report that was already queued when the user paused doesn't count.
        guard items[id]?.state == .downloading else { return }
        // Progress arrives many times a second; the list needs about one update a second.
        let now = Date()
        if let last = lastPublished[id], now.timeIntervalSince(last) < 0.8 { return }
        if let last = lastPublished[id], let previous = items[id]?.written, written > previous {
            let instant = Double(written - previous) / now.timeIntervalSince(last)
            // Smoothed, so the figure doesn't jump about with every report.
            speeds[id] = speeds[id].map { $0 * 0.7 + instant * 0.3 } ?? instant
        }
        lastPublished[id] = now
        update(id, persist: false) {
            $0.written = written
            if expected > 0 { $0.expected = expected }
        }
        if let item = items[id] { onProgress?(item, speeds[id]) }
    }

    fileprivate func finished(_ id: String, fileName: String) {
        update(id) {
            $0.fileName = fileName
            $0.state = .finished
            $0.written = max($0.written, $0.expected)
        }
        speeds[id] = nil
        lastPublished[id] = nil
        recountBytes()
        if let item = items[id] {
            onEvent?(.finished(item))
            fetchSubtitles(for: item)
        }
    }

    fileprivate func failed(_ id: String, message: String, canResume: Bool, status: Int? = nil) {
        guard items[id] != nil else { return }
        update(id) {
            $0.state = canResume ? .paused : .failed(message)
            $0.refusedStatus = status
        }
        speeds[id] = nil
        lastPublished[id] = nil
        if !canResume, let item = items[id] {
            onEvent?(.failed(item, message))
            AppLog.record("Download \(item.target.displayTitle)", message)
        }
    }

    fileprivate func finishBackgroundEvents() {
        // The system may wake the app for this without ever making a scene active, so the handler
        // can still be parked on the app delegate.
        let completion = backgroundCompletion ?? AppDelegate.pendingBackgroundCompletion
        backgroundCompletion = nil
        AppDelegate.pendingBackgroundCompletion = nil
        completion?()
    }

    // MARK: Subtitles

    /// Saves subtitles in the preferred language beside the video, so they work offline too.
    private func fetchSubtitles(for item: DownloadItem) {
        let languages = subtitleLanguages[item.id] ?? []
        guard !languages.isEmpty else { return }
        let folder = folder
        let id = item.id
        Task { [weak self] in
            let results = (try? await OnlineSubtitles.search(kind: item.target.item.kind, videoID: item.target.videoID,
                                                             filename: item.source.file ?? item.source.release,
                                                             size: item.source.sizeBytes)) ?? []
            guard let pick = results.first(where: { languages.contains($0.language) }),
                  let response = try? await HTTP.session.data(from: pick.url), !response.0.isEmpty else { return }
            let data = response.0
            let name = "\(DownloadRelay.safeName(id)).\(pick.language).srt"
            guard (try? data.write(to: folder.appendingPathComponent(name), options: .atomic)) != nil else { return }
            self?.update(id) { $0.subtitleFiles = [name] }
        }
    }

    // MARK: Helpers

    private func request(_ url: URL, cellular: Bool) -> URLRequest {
        var request = URLRequest(url: url)
        request.allowsCellularAccess = cellular
        request.allowsExpensiveNetworkAccess = cellular
        request.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private func begin(_ task: URLSessionDownloadTask, id: String) {
        task.taskDescription = id
        if let item = items[id], item.source.sizeBytes > 0 { task.countOfBytesClientExpectsToReceive = Int64(item.source.sizeBytes) }
        task.resume()
    }

    private func removeFiles(of item: DownloadItem) {
        if let name = item.fileName { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
        for name in item.subtitleFiles ?? [] { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
        _ = relay.takeResumeData(for: item.id)
    }

    private func recountBytes() {
        let folder = folder
        let names = items.values.flatMap { [$0.fileName].compactMap { $0 } + ($0.subtitleFiles ?? []) }
        Task.detached(priority: .utility) { [weak self] in
            let total = names.compactMap { name -> Int64? in
                let attributes = try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)
                return (attributes?[.size] as? NSNumber)?.int64Value
            }.reduce(0, +)
            await MainActor.run { [weak self] in
                if self?.usedBytes != total { self?.usedBytes = total }
            }
        }
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
        writer.schedule(after: 0.3) { try? JSONEncoder().encode(snapshot) }
    }
}

/// The session's delegate. URLSession calls it on its own queue, and the downloaded file must be
/// moved before `didFinishDownloadingTo` returns, so the move happens here and only the result
/// goes to the main actor.
private final class DownloadRelay: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    weak var store: DownloadStore?
    private let folder: URL

    init(folder: URL) { self.folder = folder }

    private func resumeURL(for id: String) -> URL {
        folder.appendingPathComponent(".\(Self.safeName(id)).resume")
    }

    func storeResumeData(_ data: Data?, for id: String) {
        guard let data else { return }
        try? data.write(to: resumeURL(for: id), options: .atomic)
    }

    func hasResumeData(for id: String) -> Bool {
        FileManager.default.fileExists(atPath: resumeURL(for: id).path)
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
            let status = http.statusCode
            let message = [403, 404, 410].contains(status)
                ? "The link expired. Retry fetches a fresh one."
                : "The server answered \(status)."
            let store = self.store; Task { @MainActor in store?.failed(id, message: message, canResume: false, status: status) }
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
