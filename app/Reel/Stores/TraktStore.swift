import Foundation
import Combine

/// Keeps the library in step with a Trakt account: the watchlist both ways, resume points and
/// watched history in, and scrobbles out while something plays. Signing in uses Trakt's device
/// flow, so no password is typed into the app. Trakt needs an API application of the user's own
/// (free, two minutes at trakt.tv/oauth/applications), because a sideloaded app cannot ship a
/// shared secret safely.
@MainActor
final class TraktStore: ObservableObject {
    enum SignIn: Equatable {
        case idle
        case waiting(code: String, url: String)
        case failed(String)
    }

    @Published private(set) var credentials: Trakt.Credentials?
    @Published private(set) var isConnected = false
    @Published private(set) var signIn: SignIn = .idle
    @Published private(set) var lastSync: Date?
    @Published private(set) var syncError: String?
    @Published private(set) var isSyncing = false

    private var token: Trakt.Token?
    private weak var library: Library?
    private var signInTask: Task<Void, Never>?

    private enum Keys {
        static let credentials = "trakt.credentials"
        static let token = "trakt.token"
    }

    init() {
        credentials = Keychain.read(Keys.credentials).flatMap { try? JSONDecoder().decode(Trakt.Credentials.self, from: Data($0.utf8)) }
        token = Keychain.read(Keys.token).flatMap { try? JSONDecoder().decode(Trakt.Token.self, from: Data($0.utf8)) }
        isConnected = credentials != nil && token != nil
    }

    func attach(_ library: Library) {
        self.library = library
        library.onWatchlistChange = { [weak self] item, included in
            self?.pushWatchlist(item, included: included)
        }
        if isConnected { Task { await sync() } }
    }

    // MARK: Connecting

    func connect(clientID: String, clientSecret: String) {
        let credentials = Trakt.Credentials(clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
                                            clientSecret: clientSecret.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !credentials.clientID.isEmpty, !credentials.clientSecret.isEmpty else {
            signIn = .failed("Enter both the Client ID and the Client Secret.")
            return
        }
        self.credentials = credentials
        save(credentials, key: Keys.credentials)
        signInTask?.cancel()
        signInTask = Task { await runDeviceFlow(credentials) }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signIn = .idle
    }

    func disconnect() {
        signInTask?.cancel()
        token = nil
        isConnected = false
        signIn = .idle
        Keychain.write("", for: Keys.token)
        library?.setExternalWatched(movies: [], episodes: [])
    }

    private func runDeviceFlow(_ credentials: Trakt.Credentials) async {
        do {
            let code = try await Trakt.deviceCode(credentials)
            signIn = .waiting(code: code.userCode, url: code.verificationURL)
            var interval = max(code.interval, 5)
            let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
            while Date() < deadline {
                try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                switch await Trakt.poll(code, credentials: credentials) {
                case .pending: continue
                case .slowDown: interval += 5
                case let .token(token):
                    store(token)
                    signIn = .idle
                    await sync()
                    return
                case let .failed(message):
                    signIn = .failed(message)
                    return
                }
            }
            signIn = .failed("The code expired. Start again.")
        } catch is CancellationError {
        } catch {
            signIn = .failed(error.localizedDescription)
        }
    }

    // MARK: Syncing

    /// Pulls the watchlist, resume points and watched history into the library.
    func sync() async {
        guard !isSyncing, let library, let credentials, let token = await validToken() else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            async let watchlist = Trakt.watchlist(credentials: credentials, token: token)
            async let resumes = Trakt.playback(credentials: credentials, token: token)
            async let watched = Trakt.watched(credentials: credentials, token: token)
            let (list, resume, history) = try await (watchlist, resumes, watched)
            library.mergeWatchlist(list)
            for entry in resume {
                library.importResume(entry.target, fraction: entry.fraction, runtime: entry.runtimeSeconds, at: entry.pausedAt)
            }
            library.setExternalWatched(movies: history.movies, episodes: history.episodes)
            lastSync = Date()
            syncError = nil
        } catch {
            syncError = error.localizedDescription
        }
    }

    private func pushWatchlist(_ item: MediaItem, included: Bool) {
        guard let credentials else { return }
        Task {
            guard let token = await validToken() else { return }
            try? await Trakt.setWatchlist(item, included: included, credentials: credentials, token: token)
        }
    }

    /// Tells Trakt what is playing. Called by the player on start, pause and exit.
    func scrobble(_ action: Trakt.ScrobbleAction, target: PlaybackTarget, position: Double, duration: Double) {
        guard isConnected, let credentials, duration > 0 else { return }
        let progress = position / duration * 100
        Task {
            guard let token = await validToken() else { return }
            try? await Trakt.scrobble(action, target: target, progress: progress, credentials: credentials, token: token)
        }
    }

    // MARK: Token

    private func validToken() async -> Trakt.Token? {
        guard let token, let credentials else { return nil }
        guard token.isExpiring else { return token }
        do {
            let fresh = try await Trakt.refresh(token, credentials: credentials)
            store(fresh)
            return fresh
        } catch {
            syncError = "Trakt sign-in expired. Connect again in Settings."
            return nil
        }
    }

    private func store(_ token: Trakt.Token) {
        self.token = token
        isConnected = true
        save(token, key: Keys.token)
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else { return }
        Keychain.write(text, for: key)
    }
}
