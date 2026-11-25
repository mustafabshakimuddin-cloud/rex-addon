import Foundation
import Network

/// Whether the device has a network path, so a failure can be put down to being offline rather
/// than to the source or the service.
final class NetworkMonitor: @unchecked Sendable {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var satisfied = true
    private var expensive = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.satisfied = path.status == .satisfied
            self.expensive = path.isExpensive
            self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "community.reel.network", qos: .utility))
    }

    var isOffline: Bool {
        lock.lock(); defer { lock.unlock() }
        return !satisfied
    }

    /// On cellular or a personal hotspot.
    var isExpensive: Bool {
        lock.lock(); defer { lock.unlock() }
        return expensive
    }
}
