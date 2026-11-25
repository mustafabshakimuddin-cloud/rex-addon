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

    private let writer: SnapshotWriter
    private static let maximumRecords = 3000

    init(fileURL: URL = JSONFile.url("sources.json")) {
        writer = SnapshotWriter(url: fileURL)
        if let saved = JSONFile.read(Saved.self, from: fileURL) {
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

    struct Saved: Codable {
        var records: [String: SourceRecord]
        var verified: [String: SourceVerification]

        init(records: [String: SourceRecord], verified: [String: SourceVerification]) {
            self.records = records
            self.verified = verified
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            records = c.lossyDictionary(SourceRecord.self, forKey: .records)
            verified = c.lossyDictionary(SourceVerification.self, forKey: .verified)
            guard c.contains(.records) || c.contains(.verified) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Not a source memory file"))
            }
        }
    }

    var snapshot: Saved { Saved(records: records, verified: verified) }

    /// Replaces everything learned with a backup's.
    func restore(_ saved: Saved) {
        records = saved.records
        verified = saved.verified
        scheduleSave()
    }

    private func scheduleSave() {
        let snapshot = snapshot
        writer.schedule(after: 1) { try? JSONEncoder().encode(snapshot) }
    }

    func saveNow() {
        let snapshot = snapshot
        writer.flush { try? JSONEncoder().encode(snapshot) }
    }
}

/// Orders sources for the automatic pick. Instant (cached) sources first, then the user's quality
/// order, and within a quality, history decides before the addon's own order does. A file that
/// failed and never worked since goes to the very end.
enum SourceRanker {
    /// What the ranking reads for one source, worked out once before sorting: the history
    /// lookups and the release-group regex are too slow to run inside the comparator.
    private struct Key {
        let source: StreamSource
        let offset: Int
        let failed: Bool
        let cached: Bool
        let sameGroup: Bool
        let quality: Int
        let preference: Double
        let score: Double
    }

    @MainActor
    static func rank(_ sources: [StreamSource], memory: SourceMemory, preferGroup bingeGroup: String? = nil,
                     preferences: SourcePreferences = .none) -> [StreamSource] {
        let keys = sources.enumerated().compactMap { offset, source -> Key? in
            guard source.isPlayable else { return nil }
            return Key(source: source, offset: offset, failed: memory.failedBefore(source), cached: source.isCached,
                       sameGroup: bingeGroup != nil && source.bingeGroup == bingeGroup, quality: source.qualityRank,
                       preference: preferences.score(source), score: memory.score(source))
        }
        let sorted = keys.sorted { a, b in
            if a.failed != b.failed { return !a.failed }
            if a.cached != b.cached { return a.cached }
            if a.sameGroup != b.sameGroup { return a.sameGroup }
            if a.quality != b.quality { return a.quality < b.quality }
            if a.preference != b.preference { return a.preference > b.preference }
            if a.score != b.score { return a.score > b.score }
            return a.offset < b.offset
        }
        return sorted.map(\.source)
    }
}
