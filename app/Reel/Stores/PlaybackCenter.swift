import Foundation
import Combine

/// What the player opens with: a resolved, directly playable address.
struct PlayerSession: Identifiable, Equatable {
    let id = UUID()
    let target: PlaybackTarget
    let url: URL
    let source: StreamSource
    let startAt: Double?
}

/// Turns "play this" into a running player: fetch Torrentio's sources, resolve the best cached
/// one through the debrid service (falling back to the next if one fails), and present it.
@MainActor
final class PlaybackCenter: ObservableObject {
    @Published var session: PlayerSession?
    @Published private(set) var preparing: PlaybackTarget?
    @Published var errorMessage: String?
    @Published var needsDebridSetup = false

    private var work: Task<Void, Never>?
    private static let maxAttempts = 3

    func play(_ target: PlaybackTarget, settings: AppSettings, library: Library, source: StreamSource? = nil, fromStart: Bool = false) {
        guard settings.isDebridConfigured else {
            needsDebridSetup = true
            return
        }
        work?.cancel()
        preparing = target
        errorMessage = nil
        let config = settings.torrentio
        let startAt = fromStart ? nil : library.resumePosition(for: target)
        work = Task { [weak self] in
            do {
                let candidates: [StreamSource]
                if let source {
                    candidates = [source]
                } else {
                    let all = try await Torrentio.streams(kind: target.item.kind, videoID: target.videoID, config: config)
                    candidates = Self.rank(all)
                    guard !candidates.isEmpty else {
                        throw PlaybackError.noSources(any: !all.isEmpty)
                    }
                }
                var lastError: Error?
                for candidate in candidates.prefix(source == nil ? Self.maxAttempts : 1) {
                    try Task.checkCancellation()
                    do {
                        let url = try await Torrentio.resolve(candidate)
                        try Task.checkCancellation()
                        self?.preparing = nil
                        self?.session = PlayerSession(target: target, url: url, source: candidate, startAt: startAt)
                        return
                    } catch let error as ResolveError where error == .accessDenied {
                        throw error  // every source will fail the same way
                    } catch {
                        lastError = error
                    }
                }
                throw lastError ?? PlaybackError.noSources(any: true)
            } catch is CancellationError {
                self?.preparing = nil
            } catch {
                self?.preparing = nil
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func cancel() {
        work?.cancel()
        work = nil
        preparing = nil
    }

    /// Cached debrid links first, keeping Torrentio's own quality order within each group.
    static func rank(_ sources: [StreamSource]) -> [StreamSource] {
        let playable = sources.filter(\.isPlayable)
        return playable.filter(\.isCached) + playable.filter { !$0.isCached }
    }
}

enum PlaybackError: LocalizedError {
    case noSources(any: Bool)

    var errorDescription: String? {
        switch self {
        case .noSources(any: true): return "Torrentio found releases, but none your debrid service can stream right now. Try the Sources list or relax the filters in Settings."
        case .noSources(any: false): return "Torrentio has no releases for this title yet."
        }
    }
}
