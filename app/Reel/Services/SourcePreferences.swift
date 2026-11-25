import Foundation

/// How much a kind of release is wanted: favoured, no opinion, or kept to the last resort.
enum Leaning: String, CaseIterable, Identifiable, Codable, Sendable {
    case prefer, neutral, avoid
    var id: String { rawValue }
    var title: String {
        switch self {
        case .prefer: return "Prefer"
        case .neutral: return "No preference"
        case .avoid: return "Avoid"
        }
    }
    var weight: Double {
        switch self {
        case .prefer: return 1
        case .neutral: return 0
        case .avoid: return -1
        }
    }
}

/// What the viewer likes in a release, beyond its resolution. Within one quality these decide
/// before history does; they never lift a 720p release above a 1080p one.
struct SourcePreferences: Equatable, Sendable {
    var hdr: Leaning = .neutral
    var dolbyVision: Leaning = .neutral
    var atmos: Leaning = .neutral
    var remux: Leaning = .neutral
    /// Release groups to favour, upper-cased ("FLUX", "NTb").
    var groups: [String] = []
    /// ISO 639-2 audio language to favour in multi-language releases; empty for none.
    var audioLanguage: String = ""
    /// Skip what this device can't show or decode in hardware.
    var matchDevice = true
    var device = DeviceSupport.assumeAll

    static let none = SourcePreferences(matchDevice: false)

    /// What the screen and chip can do; filled in by the app at launch.
    struct DeviceSupport: Equatable, Sendable {
        var hdr: Bool
        var dolbyVision: Bool
        var av1: Bool
        static let assumeAll = DeviceSupport(hdr: true, dolbyVision: true, av1: true)
    }

    func score(_ source: StreamSource) -> Double {
        var score = 0.0
        let isDV = source.hasDolbyVision
        let isHDR = source.hasHDR
        if isHDR { score += hdr.weight * 3 }
        if isDV { score += dolbyVision.weight * 3 }
        if source.tags.contains("Atmos") { score += atmos.weight * 2 }
        if source.tags.contains("Remux") { score += remux.weight * 2 }
        if let group = source.releaseGroup, groups.contains(where: { $0.caseInsensitiveCompare(group) == .orderedSame }) { score += 4 }
        if !audioLanguage.isEmpty, Self.mentions(language: audioLanguage, in: source) { score += 2 }
        if matchDevice {
            // A Dolby Vision-only file (profile 5) shows wrong colours where DV isn't supported;
            // HDR on an SDR screen is tone-mapped and loses the point of the bigger file.
            if isDV && !device.dolbyVision { score -= 3 }
            if isHDR && !device.hdr { score -= 2 }
            if source.tags.contains("AV1") && !device.av1 { score -= 6 }
        }
        return score
    }

    /// Whether a release's name or language line names a language ("ITA", "German", 🇩🇪…).
    static func mentions(language code: String, in source: StreamSource) -> Bool {
        let words = Languages.searchTerms(for: code)
        guard !words.isEmpty else { return false }
        let haystack = [source.release, source.file ?? "", source.languages ?? ""].joined(separator: " ").lowercased()
        return words.contains { word in
            let isFlag = word.unicodeScalars.contains { (0x1F1E6...0x1F1FF).contains($0.value) }
            if isFlag || word.count > 3 { return haystack.contains(word) }
            return haystack.range(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b", options: .regularExpression) != nil
        }
    }
}
