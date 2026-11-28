import Foundation
import AetherEngine

/// Labels both players (iPhone and Apple TV) show.
extension PlayerView {
    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.isFinite ? max(0, seconds) : 0)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func rateLabel(_ rate: Float) -> String {
        rate == 1 ? "Speed" : (rate.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(rate))×" : "\(rate)×")
    }

    static func formatLabel(_ format: VideoFormat) -> String? {
        switch format {
        case .dolbyVision: return "Dolby Vision"
        case .hdr10Plus: return "HDR10+"
        case .hdr10: return "HDR10"
        case .hlg: return "HLG"
        default: return nil
        }
    }
}
