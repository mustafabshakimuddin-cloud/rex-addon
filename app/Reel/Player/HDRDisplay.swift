import Foundation
import AetherEngine
#if os(macOS)
import AppKit
#endif

/// How HDR reaches the display, from Settings → Player → HDR on This Display.
///
/// On the Mac, Dolby Vision and HDR10+ already go through Apple's own mapping, which fits the
/// picture to whatever HDR display is attached, as long as the engine sends them as such:
/// - Dolby Vision: the engine can't see whether a Mac presents it, so it would serve Profile 7 and
///   AV1 Dolby Vision as their HDR10 base layer. With the setting on, an HDR display is declared
///   able (`panelPresentsDolbyVision`); if AVFoundation disagrees, the engine falls back to the
///   base layer once, in place.
/// - HDR10+: the dynamic metadata is applied by Apple's player; the engine's tone map stays out of
///   its way so the picture isn't mapped twice.
/// - HDR10 graded brighter than the display: the engine's BT.2390 tone map brings it down to the
///   display's peak (`videoProcessing`), so a 400 or 600 nit monitor doesn't clip the highlights.
@MainActor
enum HDRDisplay {
    struct Options: Equatable {
        var videoProcessing: VideoProcessingOptions?
        var presentsDolbyVision = false
    }

    static func options(_ settings: AppSettings) -> Options {
        #if os(macOS)
        let display = AetherEngine.displayCapabilities
        guard display.supportsHDR else { return Options() }
        var options = Options()
        options.presentsDolbyVision = settings.mapDolbyVision
        if settings.toneMapHDR, let peak = settings.displayPeakNits > 0 ? settings.displayPeakNits : estimatedPeakNits {
            options.videoProcessing = VideoProcessingOptions(targetPeakNits: peak)
        }
        return options
        #else
        return Options()
        #endif
    }

    /// The display's peak brightness, estimated from how far above SDR white macOS lets it go:
    /// about 1600 nit on a Pro Display XDR or MacBook Pro, 400 to 600 on most HDR10 monitors.
    /// nil when the display has no HDR headroom.
    static var estimatedPeakNits: Double? {
        #if os(macOS)
        guard let screen = NSApplication.shared.keyWindow?.screen ?? NSScreen.main else { return nil }
        let headroom = Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue)
        guard headroom > 1.05 else { return nil }
        return min(max(headroom * 100, 300), 2000).rounded()
        #else
        return nil
        #endif
    }

    /// Peaks to choose from in Settings; 0 is Automatic.
    static let peakChoices: [Double] = [0, 400, 600, 800, 1000, 1400, 1600, 2000]
}
