import Foundation
import Combine

/// What happened the times a file, a release group or an addon was played.
struct SourceRecord: Codable, Hashable {
    var successes = 0
    var failures = 0
    var stalls = 0
    var lastFailure: String?
    var updatedAt = Date()

    /// Positive when it has worked more than it has failed.
    var balance: Int { successes - 2 * failures }
}

/// What the engine read from the file itself, before anyone pressed Play.
struct SourceVerification: Codable, Hashable {
    var videoFormat: String          // "Dolby Vision", "HDR10+", "HDR10", "HLG", "SDR"
    var dolbyVisionProfile: Int?
    var resolution: String?          // "3840×2160"
    var bitDepth: Int?
    var codec: String?
    var atmos: Bool
    var audio: String?               // "E-AC-3 · 5.1"
    var checkedAt = Date()

    var badges: [String] {
        var badges: [String] = []
        if videoFormat != "SDR" {
            badges.append(dolbyVisionProfile.map { "\(videoFormat) P\($0)" } ?? videoFormat)
        }
        if atmos { badges.append("Atmos") }
        if let bitDepth, bitDepth > 8 { badges.append("\(bitDepth)-bit") }
        return badges
    }
}

/// Learns which sources actually play, so the next pick avoids what failed and favours what
/// worked. Three levels, from most to least specific: the exact file, the release group that
/// made it, and the addon that listed it. Kept in a small JSON file.
@MainActor
final class SourceMemory: ObservableObject {
    @Published private(set) var records: [String: SourceRecord] = [:]
    @Published private(set) var verified: [String: SourceVerification] = [:]

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?
    private static let maximumRecords = 3000

    init() {
        let folder = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        fileURL = folder.appendingPathComponent("sources.json")
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            records = saved.records
            verified = saved.verified
        }
    }

    // MARK: Reading

    func record(for source: StreamSource) -> SourceRecord? { records[Self.fileKey(source)] }
    func groupRecord(for source: StreamSource) -> SourceRecord? { source.releaseGroup.flatMap { records["group:\($0)"] } }
    func verification(for source: StreamSource) -> SourceVerification? { verified[source.fileKey] }

    /// How strongly history argues for this source. The file's own history dominates; a release
    /// group only nudges, because one bad encode says little about a group's next one.
    func score(_ source: StreamSource) -> Double {
        var score = 0.0
        if let file = record(for: source) {
            score += Double(file.balance) * 4
            if file.failures > file.successes { score -= 100 }
        }
        if let group = groupRecord(for: source) { score += Double(max(-5, min(5, group.balance))) }
        if let addon = records["addon:\(source.addon)"] { score += Double(max(-2, min(2, addon.balance))) * 0.5 }
        return score
    }

    /// Whether the file failed the last time it was tried and never worked since.
    func failedBefore(_ source: StreamSource) -> Bool {
        guard let file = record(for: source) else { return false }
        return file.failures > file.successes
    }

    func playedWell(_ source: StreamSource) -> Bool {
        guard let file = record(for: source) else { return false }
        return file.successes > 0 && file.failures == 0
    }

    // MARK: Writing

    func noteSuccess(_ source: StreamSource) {
        update(source) { $0.successes += 1 }
    }

    func noteFailure(_ source: StreamSource, reason: String) {
        update(source) {
            $0.failures += 1
            $0.lastFailure = reason
        }
    }

    func noteStall(_ source: StreamSource) {
        update(source, fileOnly: true) { $0.stalls += 1 }
    }

    func store(_ verification: SourceVerification, for source: StreamSource) {
        verified[source.fileKey] = verification
        scheduleSave()
    }

    func forgetAll() {
        records = [:]
        verified = [:]
        scheduleSave()
    }

    private func update(_ source: StreamSource, fileOnly: Bool = false, _ change: (inout SourceRecord) -> Void) {
        var keys = [Self.fileKey(source)]
        if !fileOnly {
            if let group = source.releaseGroup { keys.append("group:\(group)") }
            keys.append("addon:\(source.addon)")
        }
        for key in keys {
            var record = records[key] ?? SourceRecord()
            change(&record)
            record.updatedAt = Date()
            records[key] = record
        }
        if records.count > Self.maximumRecords {
            let overflow = records.sorted { $0.value.updatedAt < $1.value.updatedAt }.prefix(records.count - Self.maximumRecords)
            for (key, _) in overflow { records[key] = nil }
        }
        scheduleSave()
    }

    private static func fileKey(_ source: StreamSource) -> String { "file:\(source.fileKey)" }

    // MARK: Persistence

    private struct Saved: Codable {
        var records: [String: SourceRecord]
        var verified: [String: SourceVerification]
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = Saved(records: records, verified: verified)
        let url = fileURL
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// Orders sources for the automatic pick. Instant (cached) sources first, then the user's quality
/// order, and within a quality, history decides before the addon's own order does. A file that
/// failed and never worked since goes to the very end.
enum SourceRanker {
    @MainActor
    static func rank(_ sources: [StreamSource], memory: SourceMemory, preferGroup bingeGroup: String? = nil) -> [StreamSource] {
        let playable = sources.enumerated().filter { $0.element.isPlayable }
        let sorted = playable.sorted { lhs, rhs in
            let a = lhs.element, b = rhs.element
            let failedA = memory.failedBefore(a), failedB = memory.failedBefore(b)
            if failedA != failedB { return !failedA }
            if a.isCached != b.isCached { return a.isCached }
            if let bingeGroup {
                let sameA = a.bingeGroup == bingeGroup, sameB = b.bingeGroup == bingeGroup
                if sameA != sameB { return sameA }
            }
            if a.qualityRank != b.qualityRank { return a.qualityRank < b.qualityRank }
            let scoreA = memory.score(a), scoreB = memory.score(b)
            if scoreA != scoreB { return scoreA > scoreB }
            return lhs.offset < rhs.offset
        }
        return sorted.map(\.element)
    }
}
