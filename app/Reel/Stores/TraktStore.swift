import Foundation
import Observation
import Combine

/// A change made here that Trakt still has to hear about. Kept on disk until Trakt accepts it, so
/// nothing done offline, or while Trakt is down, is lost.
enum TraktChange: Codable, Hashable {
    case watchlist(MediaItem, added: Bool)
    case history([PlaybackTarget], watched: Bool, at: Date)
    case rating(MediaItem, Int)
}

/// Keeps the library in step with a Trakt account: the watchlist and watched history both ways,
/// resume points in, and scrobbles out while something plays. Signing in uses Trakt's device
/// flow, so no password is typed into the app. Trakt needs an API application of the user's own
/// (free, two minutes at trakt.tv/oauth/applications), because a sideloaded app cannot ship a
/// shared secret safely.
@MainActor
@Observable
final class TraktStore {
    enum SignIn: Equatable {
        case idle
        case waiting(code: String, url: String)
        case failed(String)
    }

    private(set) var credentials: Trakt.Credentials?
    private(set) var isConnected = false
    private(set) var signIn: SignIn = .idle
    private(set) var lastSync: Date?
    private(set) var syncError: String?
    private(set) var isSyncing = false
    /// Changes waiting to reach Trakt.
    private(set) var pending: [TraktChange] = []

    private var token: Trakt.Token?
    @ObservationIgnored private weak var library: Library?
    private var signInTask: Task<Void, Never>?
    /// The one refresh in flight: Trakt's refresh tokens work once, so two refreshing together
    /// would sign the app out.
    private var refreshTask: Task<Trakt.Token?, Never>?
    private var flushTask: Task<Void, Never>?
    /// The send in progress: two at once would both send the head of the queue, then each remove
    /// one entry, dropping a change that was never sent.
    private var sendTask: Task<Void, Never>?
    /// Moves on every profile switch, so work begun for one account never lands in another's
    /// library, queue or keys.
    private var generation = 0
    private var queueWriter = SnapshotWriter(url: JSONFile.url("trakt-queue.json"))
    /// The profile whose Trakt account this is.
    private var profile = Profile(id: Profile.defaultID, name: "Me", symbol: "person.fill")
    private let defaults = UserDefaults.standard

    /// The API application is shared by everyone on the device; the sign-in and what's waiting
    /// to be sent belong to a profile.
    private struct Keys {
        static let credentials = "trakt.credentials"
        let token: String
        let activities: String
    }

    private var keys: Keys { Keys(token: profile.key("trakt.token"), activities: profile.key("trakt.lastActivities")) }

    init() {
        credentials = Keychain.read(Keys.credentials).flatMap { try? JSONDecoder().decode(Trakt.Credentials.self, from: Data($0.utf8)) }
        token = Keychain.read(Profile(id: Profile.defaultID, name: "", symbol: "").key("trakt.token"))
            .flatMap { try? JSONDecoder().decode(Trakt.Token.self, from: Data($0.utf8)) }
        isConnected = credentials != nil && token != nil
        pending = JSONFile.read([Lossy<TraktChange>].self, from: JSONFile.url("trakt-queue.json"))?.compactMap(\.value) ?? []
    }

    /// Signs in as another profile's Trakt account, or none: its token, its queue, a fresh sync.
    func switchProfile(_ profile: Profile) {
        saveQueue()
        queueWriter.waitUntilWritten()
        signInTask?.cancel()
        refreshTask = nil
        sendTask = nil
        flushTask?.cancel()
        // A sync still running for the previous profile finds the generation moved and stops;
        // this profile's own sync must not wait for it.
        generation += 1
        isSyncing = false
        self.profile = profile
        queueWriter = SnapshotWriter(url: profile.file("trakt-queue"))
        pending = JSONFile.read([Lossy<TraktChange>].self, from: profile.file("trakt-queue"))?.compactMap(\.value) ?? []
        token = Keychain.read(keys.token).flatMap { try? JSONDecoder().decode(Trakt.Token.self, from: Data($0.utf8)) }
        isConnected = credentials != nil && token != nil
        signIn = .idle
        syncError = nil
        lastSync = nil
        if isConnected { Task { await sync() } }
    }

    func attach(_ library: Library) {
        self.library = library
        library.onWatchlistChange = { [weak self] item, included in
            self?.enqueue(.watchlist(item, added: included))
        }
        library.onWatchedChange = { [weak self] targets, watched in
            self?.enqueue(.history(targets, watched: watched, at: Date()))
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
        syncError = nil
        pending = []
        saveQueue()
        defaults.removeObject(forKey: keys.activities)
        Keychain.write("", for: keys.token)
        library?.forgetTraktState()
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
                    syncError = nil
                    defaults.removeObject(forKey: keys.activities)
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

    /// Sends what is waiting, then pulls the watchlist, resume points and watched history,
    /// skipping the parts Trakt says haven't changed since the last sync.
    func sync(force: Bool = false) async {
        guard !isSyncing, let library, let credentials else { return }
        let generation = self.generation
        let keys = self.keys
        isSyncing = true
        defer { if generation == self.generation { isSyncing = false } }
        guard let token = await validToken(), generation == self.generation else { return }
        await flush()
        guard generation == self.generation else { return }
        do {
            let activities = try await Trakt.lastActivities(credentials: credentials, token: token)
            let previous = force ? [:] : (defaults.dictionary(forKey: keys.activities) as? [String: String] ?? [:])
            func changed(_ key: String) -> Bool { previous[key] == nil || previous[key] != activities[key] }

            async let watchlist = Self.fetch(if: changed("watchlist")) { try await Trakt.watchlist(credentials: credentials, token: token) }
            async let resumes = Self.fetch(if: changed("playback")) { try await Trakt.playback(credentials: credentials, token: token) }
            async let watched = Self.fetch(if: changed("watched")) { try await Trakt.watched(credentials: credentials, token: token) }
            let (list, resume, history) = try await (watchlist, resumes, watched)
            // Another profile was chosen meanwhile: this account's lists aren't its business.
            guard generation == self.generation else { return }

            if let list {
                library.applyTraktWatchlist(list, pendingAdds: pendingWatchlist(added: true), pendingRemovals: pendingWatchlist(added: false))
            }
            for entry in resume ?? [] {
                library.importResume(entry.target, fraction: entry.fraction, runtime: entry.runtimeSeconds, at: entry.pausedAt)
            }
            if let history { library.setExternalWatched(movies: history.movies, episodes: history.episodes) }
            defaults.set(activities, forKey: keys.activities)
            lastSync = Date()
            syncError = nil
        } catch {
            guard generation == self.generation else { return }
            syncError = Self.describe(error)
            AppLog.record("Trakt sync", error)
        }
    }

    private static func fetch<T: Sendable>(if needed: Bool, _ work: () async throws -> T) async throws -> T? {
        needed ? try await work() : nil
    }

    private func pendingWatchlist(added: Bool) -> Set<String> {
        Set(pending.compactMap { change in
            if case let .watchlist(item, value) = change, value == added { return item.id }
            return nil
        })
    }

    // MARK: Changes

    private func enqueue(_ change: TraktChange) {
        guard credentials != nil, isConnected else { return }
        // A later change to the same title's watchlist entry replaces the earlier one.
        if case let .watchlist(item, _) = change {
            pending.removeAll { if case let .watchlist(other, _) = $0 { return other.id == item.id } else { return false } }
        }
        pending.append(change)
        saveQueue()
        scheduleFlush()
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            // A short pause gathers a burst of changes (a season marked episode by episode).
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    /// Sends waiting changes in order. A change Trakt refuses outright is dropped; a network
    /// failure stops the run, to be tried again at the next sync.
    func flush() async {
        // One run at a time; a second caller waits for it. The run reads the queue live, so
        // changes added while it is under way go out in the same run.
        if let sendTask {
            await sendTask.value
            return
        }
        let task = Task { await self.send() }
        sendTask = task
        await task.value
        if sendTask == task { sendTask = nil }
    }

    private func send() async {
        let generation = self.generation
        guard let credentials, !pending.isEmpty, let token = await validToken(), generation == self.generation else { return }
        sending: while generation == self.generation, let change = pending.first {
            do {
                switch change {
                case let .watchlist(item, added):
                    try await Trakt.setWatchlist(item, included: added, credentials: credentials, token: token)
                case let .history(targets, watched, date):
                    try await Trakt.history(targets, watched: watched, at: date, credentials: credentials, token: token)
                case let .rating(item, rating):
                    try await Trakt.rate(item, rating: rating, credentials: credentials, token: token)
                }
                settle(change, generation: generation)
            } catch let Trakt.TraktError.status(code) where (400..<500).contains(code) && code != 401 && code != 429 {
                settle(change, generation: generation)  // Trakt won't ever take it
            } catch {
                break sending
            }
        }
        if generation == self.generation { saveQueue() }
    }

    /// Takes a change Trakt has dealt with off the queue. Found by value, not position: while it
    /// was being sent, a newer change to the same watchlist entry may have replaced it.
    private func settle(_ change: TraktChange, generation: Int) {
        guard generation == self.generation, let index = pending.firstIndex(of: change) else { return }
        pending.remove(at: index)
    }

    /// Rates a title on Trakt, from 1 to 10.
    func rate(_ item: MediaItem, rating: Int) {
        enqueue(.rating(item, rating))
    }

    /// Tells Trakt what is playing. Called by the player on start, pause and exit. A stop that
    /// can't be sent, near the end, is kept as a watched mark instead.
    func scrobble(_ action: Trakt.ScrobbleAction, target: PlaybackTarget, position: Double, duration: Double) {
        guard isConnected, let credentials, duration > 0 else { return }
        let progress = position / duration * 100
        Task {
            guard let token = await validToken() else { return }
            do {
                try await Trakt.scrobble(action, target: target, progress: progress, credentials: credentials, token: token)
            } catch Trakt.TraktError.status(409) {
                // Trakt already recorded this play a moment ago; marking it again would count twice.
            } catch {
                if action == .stop, progress >= 80 { enqueue(.history([target], watched: true, at: Date())) }
            }
        }
    }

    // MARK: Lists

    func discover(_ list: Trakt.Discovery, kind: MediaKind) async throws -> [MediaItem] {
        guard let credentials else { return [] }
        let token = list.needsSignIn ? await validToken() : nil
        if list.needsSignIn && token == nil { return [] }
        return try await Trakt.discover(list, kind: kind, credentials: credentials, token: token)
    }

    /// Titles related to this one, from Trakt; needs only the API application, not a sign-in.
    func related(_ item: MediaItem) async throws -> [MediaItem] {
        guard let credentials else { return [] }
        return try await Trakt.related(item, credentials: credentials)
    }

    func lists() async throws -> [Trakt.List] {
        guard let credentials, let token = await validToken() else { return [] }
        return try await Trakt.lists(credentials: credentials, token: token)
    }

    func items(of list: Trakt.List) async throws -> [MediaItem] {
        guard let credentials, let token = await validToken() else { return [] }
        return try await Trakt.listItems(list, credentials: credentials, token: token)
    }

    // MARK: Token

    private func validToken() async -> Trakt.Token? {
        guard let token, let credentials else { return nil }
        guard token.isExpiring else { return token }
        if let refreshTask { return await refreshTask.value }
        let generation = self.generation
        let tokenKey = keys.token
        let task = Task<Trakt.Token?, Never> { [weak self] in
            do {
                let fresh = try await Trakt.refresh(token, credentials: credentials)
                // Saved under the account it belongs to, even if another profile is in use now.
                self?.save(fresh, key: tokenKey)
                if let self, generation == self.generation { self.token = fresh; self.isConnected = true }
                return fresh
            } catch let Trakt.TraktError.status(code) where code == 400 || code == 401 {
                self?.syncError = "Trakt sign-in expired. Connect again in Settings."
                return nil
            } catch {
                // Offline or Trakt down: the old token still works until it actually expires.
                if token.expiresAt > Date() { return token }
                self?.syncError = Self.describe(error)
                return nil
            }
        }
        refreshTask = task
        let result = await task.value
        if generation == self.generation { refreshTask = nil }
        return result
    }

    private static func describe(_ error: Error) -> String {
        if HTTP.isOffline(error) { return "Couldn't reach Trakt. It will sync when you're back online." }
        return error.localizedDescription
    }

    private func store(_ token: Trakt.Token) {
        self.token = token
        isConnected = true
        save(token, key: keys.token)
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else { return }
        Keychain.write(text, for: key)
    }

    private func saveQueue() {
        let snapshot = pending
        queueWriter.schedule(after: 0.2) { try? JSONEncoder().encode(snapshot) }
    }
}
