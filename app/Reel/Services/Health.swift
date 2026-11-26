import Foundation
import Observation
import Combine

/// Checks the key the way playback will use it, without changing the account: the service's own
/// account page says whether the key is accepted and when the plan ends, and a Torrentio search
/// with the key must come back with instant releases. Nothing is resolved, so no torrent is added
/// to the account (resolving is what adds one).
enum DebridCheck {
    struct Pass: Sendable {
        let summary: String
        let account: DebridAccountInfo?
    }

    static func run(_ base: TorrentioConfig) async -> Result<Pass, Error> {
        var config = base
        config.cachedOnly = true
        do {
            var account: DebridAccountInfo?
            do {
                account = try await DebridAccount.info(service: config.service, key: config.key)
            } catch DebridAccountError.unsupported {
                account = nil
            }
            let sources = try await Torrentio.streams(kind: .movie, videoID: "tt0111161", config: config)
            guard sources.contains(where: { $0.isCached && $0.isPlayable }) else {
                return .failure(CheckError("No instant sources came back. The key may be wrong, or the service may be down."))
            }
            var summary = "Working"
            if let days = account?.daysLeft { summary += days <= 0 ? ", plan ends today" : ", \(days) day\(days == 1 ? "" : "s") left" }
            return .success(Pass(summary: summary, account: account))
        } catch {
            return .failure(error)
        }
    }
}

struct CheckError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// One line of the Status page: what was checked, how it went, and what to do about it.
struct HealthCheck: Identifiable, Hashable {
    enum Level: Int, Comparable {
        case ok, notSet, warning, problem
        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }

        var label: String {
            switch self {
            case .ok: return "OK"
            case .notSet: return "Not set"
            case .warning: return "WARN"
            case .problem: return "FAIL"
            }
        }
    }

    /// Where the fix lives.
    enum Fix: Hashable {
        case settings(SettingsPage)
        case settingsHome
        case setup
        case downloads
        case link(URL)
    }

    let id: String
    let title: String
    let systemImage: String
    var level: Level
    var detail: String
    var advice: String?
    var fix: Fix?
    var fixTitle: String?
}

/// Runs every check at once, each with its own time limit, so one slow service never holds up
/// the page.
@MainActor
@Observable
final class HealthModel {
    private(set) var checks: [HealthCheck] = []
    private(set) var isRunning = false
    private(set) var ranAt: Date?

    var worst: HealthCheck.Level { checks.map(\.level).max() ?? .ok }
    var problemCount: Int { checks.filter { $0.level == .problem }.count }
    var warningCount: Int { checks.filter { $0.level == .warning }.count }

    var summary: String {
        if isRunning && checks.isEmpty { return "Checking…" }
        switch (problemCount, warningCount) {
        case (0, 0): return "Everything is working"
        case (0, let w): return w == 1 ? "1 thing to look at" : "\(w) things to look at"
        case (let p, 0): return p == 1 ? "1 problem" : "\(p) problems"
        case (let p, let w): return "\(p) problem\(p == 1 ? "" : "s"), \(w) to look at"
        }
    }

    /// Plain text for sharing, one check per line, like a command-line doctor.
    var report: String {
        var lines = ["\(AppConfig.name) status, \(Date().formatted(date: .abbreviated, time: .shortened))"]
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            lines.append("Version \(version)")
        }
        lines.append("")
        for check in checks {
            lines.append("[\(check.level.label)] \(check.title): \(Redact.text(check.detail))")
            if let advice = check.advice, check.level != .ok { lines.append("       Fix: \(advice)") }
        }
        let log = AppLog.entries.prefix(20)
        if !log.isEmpty {
            lines.append("")
            lines.append("Recent errors:")
            for entry in log {
                lines.append("  \(entry.date.formatted(date: .numeric, time: .standard)) \(entry.area): \(entry.message)")
            }
        }
        return lines.joined(separator: "\n")
    }

    func run(settings: AppSettings, trakt: TraktStore, downloads: DownloadStore, memory: SourceMemory) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false; ranAt = Date() }

        // Instant checks first, so the page fills straight away.
        var instant: [HealthCheck] = [streamingCheck(settings), rulesCheck(settings), historyCheck(memory), traktCheck(trakt)]
        // Offline copies are an extra; their checks only appear once there are some.
        if !downloads.items.isEmpty { instant += [downloadsCheck(downloads), storageCheck(downloads)] }
        if !settings.setupFinished {
            instant.insert(HealthCheck(id: "setup", title: "Setup", systemImage: "wand.and.stars", level: .notSet,
                                       detail: "Setup was not finished.", advice: "Run setup to choose how titles play.",
                                       fix: .setup, fixTitle: "Run Setup"), at: 0)
        }
        let config = settings.torrentio
        let addons = settings.addons.filter(\.enabled)
        checks = instant + pendingNetworkChecks(config: config, addons: addons)

        let torrentioURL = "\(config.serverBase)/manifest.json"
        await withTaskGroup(of: HealthCheck?.self) { group in
            group.addTask { await self.debridCheck(config, settings: settings) }
            if let second = settings.secondaryTorrentio {
                group.addTask { await self.debridCheck(second, settings: settings, primary: false) }
            }
            group.addTask {
                await self.reachCheck(id: "cinemeta", title: "Catalogue", systemImage: "square.grid.2x2",
                                      url: "https://v3-cinemeta.strem.io/manifest.json", service: "Cinemeta")
            }
            group.addTask {
                await self.reachCheck(id: "torrentio", title: "Torrentio", systemImage: "magnifyingglass.circle",
                                      url: torrentioURL, service: "Torrentio")
            }
            for addon in addons {
                group.addTask { await self.addonCheck(addon) }
            }
            // Each row is filled in as its check finishes, not when the slowest one does.
            for await check in group {
                guard let check else { continue }
                if let index = checks.firstIndex(where: { $0.id == check.id }) { checks[index] = check } else { checks.append(check) }
            }
        }
    }

    // MARK: Checks

    private func pendingNetworkChecks(config: TorrentioConfig, addons: [StreamAddon]) -> [HealthCheck] {
        var pending = [
            HealthCheck(id: "cinemeta", title: "Catalogue", systemImage: "square.grid.2x2", level: .ok, detail: "Checking…"),
            HealthCheck(id: "torrentio", title: "Torrentio", systemImage: "magnifyingglass.circle", level: .ok, detail: "Checking…"),
        ]
        if config.hasDebrid {
            pending.append(HealthCheck(id: "debrid", title: config.service.name, systemImage: "key", level: .ok, detail: "Checking…"))
        }
        pending += addons.map {
            HealthCheck(id: "addon:\($0.id)", title: $0.name, systemImage: "puzzlepiece.extension", level: .ok, detail: "Checking…")
        }
        return pending
    }

    private func streamingCheck(_ settings: AppSettings) -> HealthCheck {
        let addons = settings.addons.filter(\.enabled).count
        guard settings.canFindSources else {
            return HealthCheck(id: "streaming", title: "Streaming", systemImage: "play.rectangle", level: .problem,
                               detail: "Nothing can play yet: there is no debrid service and no addon.",
                               advice: "Add a debrid service such as Real-Debrid, or a Stremio addon that gives direct links.",
                               fix: .setup, fixTitle: "Set Up")
        }
        var parts: [String] = []
        if settings.isDebridConfigured { parts.append(settings.debridService.name) }
        if addons > 0 { parts.append(addons == 1 ? "1 addon" : "\(addons) addons") }
        return HealthCheck(id: "streaming", title: "Streaming", systemImage: "play.rectangle", level: .ok,
                           detail: "Plays through \(parts.joined(separator: " and ")).")
    }

    /// What decides which release plays, in a line. Warns when Play may pick a release the
    /// debrid service still has to fetch, which won't start until it has.
    private func rulesCheck(_ settings: AppSettings) -> HealthCheck {
        var parts: [String] = [settings.autoPlayBest ? "Play starts the best source" : "Play lists sources to pick from"]
        if settings.maxSizeGB > 0 { parts.append("up to \(settings.maxSizeGB) GB") }
        if !settings.excludedQualities.isEmpty {
            parts.append("hides " + settings.excludedQualities.map(SettingsView.qualityLabel).joined(separator: ", "))
        }
        if settings.isDebridConfigured && !settings.cachedOnly {
            return HealthCheck(id: "rules", title: "Pick rules", systemImage: "slider.horizontal.3", level: .warning,
                               detail: "Instant only is off, so the list includes releases \(settings.debridService.name) hasn't cached. Those don't stream until the service has fetched them.",
                               advice: "Turn on Instant sources only for streams that start straight away.",
                               fix: .settings(.pickRules), fixTitle: "Pick Rules")
        }
        return HealthCheck(id: "rules", title: "Pick rules", systemImage: "slider.horizontal.3", level: .ok,
                           detail: (settings.isDebridConfigured ? "Instant only; " : "") + parts.joined(separator: ", ") + ".",
                           fix: .settings(.pickRules), fixTitle: "Pick Rules")
    }

    private func debridCheck(_ config: TorrentioConfig, settings: AppSettings, primary: Bool = true) async -> HealthCheck? {
        guard config.hasDebrid else { return nil }
        let id = primary ? "debrid" : "debrid2"
        let result = await DebridCheck.run(config)
        switch result {
        case let .success(pass):
            if primary { settings.debridAccount = pass.account }
            var detail = "Key accepted; instant sources found."
            if let account = pass.account, let expires = account.expires {
                detail += " Plan ends \(expires.formatted(date: .abbreviated, time: .omitted))."
            }
            if let days = pass.account?.daysLeft, days <= 7 {
                return HealthCheck(id: id, title: config.service.name, systemImage: "key", level: .warning,
                                   detail: detail, advice: "Renew the plan, or streams stop when it ends.",
                                   fix: config.service.accountPage.map(HealthCheck.Fix.link), fixTitle: "Renew")
            }
            return HealthCheck(id: id, title: config.service.name, systemImage: "key", level: .ok, detail: detail)
        case let .failure(error):
            return HealthCheck(id: id, title: config.service.name, systemImage: "key", level: .problem,
                               detail: Redact.text(error.localizedDescription),
                               advice: "Check the API key in Settings. If it is right, the service may be down or your plan may have ended.",
                               fix: config.service.keyPage.map(HealthCheck.Fix.link) ?? .settingsHome,
                               fixTitle: config.service.keyPage == nil ? "Settings" : "Get Key")
        }
    }

    private func reachCheck(id: String, title: String, systemImage: String, url: String, service: String) async -> HealthCheck {
        if let failure = await Self.reach(url) {
            return HealthCheck(id: id, title: title, systemImage: systemImage, level: .problem,
                               detail: "\(service) didn't answer: \(failure)",
                               advice: "Check your internet connection. If it works elsewhere, \(service) may be down for a while.")
        }
        return HealthCheck(id: id, title: title, systemImage: systemImage, level: .ok, detail: "\(service) is answering.")
    }

    private func addonCheck(_ addon: StreamAddon) async -> HealthCheck {
        let started = Date()
        let failure = await Self.reach("\(addon.base)/manifest.json")
        let id = "addon:\(addon.id)"
        guard let failure else {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            return HealthCheck(id: id, title: addon.name, systemImage: "puzzlepiece.extension", level: .ok,
                               detail: "Answering at \(URL(string: addon.base)?.host ?? "its address") in \(ms) ms."
                                   + (addon.base.hasPrefix("http://") ? " Its address isn't encrypted." : ""))
        }
        return HealthCheck(id: id, title: addon.name, systemImage: "puzzlepiece.extension", level: .warning,
                           detail: "Didn't answer: \(Redact.text(failure))",
                           advice: "Turn it off under Stremio Addons, or install it again from its configure page.",
                           fix: .settings(.addons), fixTitle: "Addons")
    }

    private func traktCheck(_ trakt: TraktStore) -> HealthCheck {
        guard trakt.isConnected else {
            return HealthCheck(id: "trakt", title: "Trakt", systemImage: "arrow.triangle.2.circlepath", level: .notSet,
                               detail: "Not connected.", advice: "Connect Trakt to keep My List and resume points in step across apps.",
                               fix: .settings(.trakt), fixTitle: "Connect")
        }
        if let error = trakt.syncError {
            return HealthCheck(id: "trakt", title: "Trakt", systemImage: "arrow.triangle.2.circlepath", level: .warning,
                               detail: error, advice: "Sync again, or connect Trakt again if the sign-in expired.",
                               fix: .settings(.trakt), fixTitle: "Trakt")
        }
        let when = trakt.lastSync.map { "Last synced \($0.formatted(date: .omitted, time: .shortened))." } ?? "Connected."
        return HealthCheck(id: "trakt", title: "Trakt", systemImage: "arrow.triangle.2.circlepath", level: .ok, detail: when)
    }

    private func downloadsCheck(_ downloads: DownloadStore) -> HealthCheck {
        let failed = downloads.problems.count, paused = downloads.paused.count, active = downloads.active.count
        if failed > 0 {
            return HealthCheck(id: "downloads", title: "Offline copies", systemImage: "arrow.down.circle", level: .warning,
                               detail: failed == 1 ? "1 download failed." : "\(failed) downloads failed.",
                               advice: "Retry them in Downloads; a fresh link is fetched if the old one expired.",
                               fix: .downloads, fixTitle: "Downloads")
        }
        var parts: [String] = ["\(downloads.finished.count) saved"]
        if active > 0 { parts.append("\(active) downloading") }
        if paused > 0 { parts.append("\(paused) paused") }
        return HealthCheck(id: "downloads", title: "Offline copies", systemImage: "arrow.down.circle", level: .ok,
                           detail: parts.joined(separator: ", ") + ".", fix: .downloads, fixTitle: "Downloads")
    }

    private func storageCheck(_ downloads: DownloadStore) -> HealthCheck {
        let used = ByteCountFormatter.string(fromByteCount: downloads.usedBytes, countStyle: .file)
        guard let free = downloads.freeBytes else {
            return HealthCheck(id: "storage", title: "Storage", systemImage: "internaldrive", level: .ok, detail: "\(used) used by downloads.")
        }
        let freeText = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
        if free < 3 << 30 {
            return HealthCheck(id: "storage", title: "Storage", systemImage: "internaldrive", level: .warning,
                               detail: "Only \(freeText) free on this device.",
                               advice: "Delete downloads you have watched, or free space in iOS Settings, before saving more.",
                               fix: .downloads, fixTitle: "Downloads")
        }
        return HealthCheck(id: "storage", title: "Storage", systemImage: "internaldrive", level: .ok,
                           detail: "\(freeText) free; downloads use \(used).")
    }

    private func historyCheck(_ memory: SourceMemory) -> HealthCheck {
        let files = memory.records.keys.filter { $0.hasPrefix("file:") }.count
        let checked = memory.verified.count
        let detail = files == 0 ? "Nothing learned yet. Picks improve as you play."
            : "Learned from \(files) release\(files == 1 ? "" : "s")" + (checked > 0 ? ", \(checked) checked for format." : ".")
        return HealthCheck(id: "memory", title: "Source ranking", systemImage: "brain", level: .ok, detail: detail)
    }

    /// nil when the address answered, otherwise why not.
    nonisolated static func reach(_ address: String) async -> String? {
        guard let url = URL(string: address) else { return "invalid address" }
        do {
            let status = try await withTimeout(seconds: 15) { () -> Int in
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
                request.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
                let (_, response) = try await HTTP.session.data(for: request)
                return (response as? HTTPURLResponse)?.statusCode ?? 0
            }
            return (200..<400).contains(status) ? nil : "HTTP \(status)"
        } catch is TimeoutError {
            return "no answer in 15 seconds"
        } catch {
            return error.localizedDescription
        }
    }
}
