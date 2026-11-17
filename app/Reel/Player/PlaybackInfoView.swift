import SwiftUI
import UIKit
import AetherEngine

/// What is actually reaching the screen: the source's format, what the engine presents, whether
/// this display can show HDR, and whether the panel is lighting highlights above SDR white right
/// now. A badge alone cannot answer "is HDR working", because a source can be HDR while the route
/// to the panel is not.
///
/// Observes the engine directly. That re-renders on every engine publish, which is fine for a panel
/// that is only alive while someone is reading it; the playback clock is not part of it.
struct PlaybackInfoView: View {
    @ObservedObject var engine: AetherEngine
    @ObservedObject var diagnostics: EngineDiagnostics
    @State private var screen: UIScreen?

    init(engine: AetherEngine) {
        self.engine = engine
        self.diagnostics = engine.diagnostics
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let headroom = screen?.currentEDRHeadroom ?? 1
                verdict(headroom: headroom)
                section("Display") {
                    line("Can show HDR", yesNo(AetherEngine.displayCapabilities.supportsHDR))
                    line("Dolby Vision", yesNo(AetherEngine.displayCapabilities.supportsDolbyVision))
                    line("Highlight boost now", Self.headroomText(headroom))
                    if let potential = screen?.potentialEDRHeadroom, potential > 1 {
                        line("Highlight boost max", Self.headroomText(potential))
                    }
                    if ProcessInfo.processInfo.isLowPowerModeEnabled {
                        line("Low Power Mode", "On")
                    }
                }
            }

            section("Video") {
                line("Source format", Self.formatName(engine.sourceVideoFormat)
                     + (engine.sourceDVProfile.map { " (Profile \($0))" } ?? ""))
                line("Presented as", Self.formatName(engine.videoFormat))
                if let stream = engine.sourceVideoStreamFormat {
                    if let transfer = stream.transferLabel { line("Transfer", transfer) }
                    if let primaries = stream.colorPrimariesLabel { line("Colour", primaries) }
                    if let depth = stream.bitDepth { line("Bit depth", "\(depth)-bit") }
                    if let profile = stream.profile { line("Profile", profile) }
                }
                line("Codec", (engine.sourceVideoCodecName ?? "–").uppercased())
                if engine.sourceVideoWidth > 0 {
                    line("Resolution", "\(engine.sourceVideoWidth) × \(engine.sourceVideoHeight)")
                }
                if let fps = engine.sourceVideoFrameRate, fps > 0 {
                    line("Frame rate", String(format: "%.3g fps", fps))
                }
                if engine.sourceVideoBitrate > 0 {
                    line("Bitrate", String(format: "%.1f Mb/s", Double(engine.sourceVideoBitrate) / 1_000_000))
                }
                if let decoder = engine.activeVideoDecoder { line("Decoder", decoder) }
                line("Route", Self.routeName(engine.videoRoute))
            }

            section("Audio") {
                if let decoder = engine.activeAudioDecoder { line("Decoder", decoder) }
                line("Delivery", Self.deliveryName(engine.audioDelivery))
            }

            if let live = diagnostics.liveTelemetry {
                section("Live") {
                    if let fps = live.observedFps { line("Frames shown", String(format: "%.1f fps", fps)) }
                    if let dropped = live.droppedFrameCount { line("Dropped frames", "\(dropped)") }
                    if let mbps = live.networkThroughputMbps { line("Network", String(format: "%.1f Mb/s", mbps)) }
                    if let ahead = live.forwardBufferSeconds { line("Buffered ahead", String(format: "%.0f s", ahead)) }
                }
            }
        }
        .background(ScreenReader { screen = $0 }.frame(width: 0, height: 0))
    }

    // MARK: Verdict

    private enum Status { case on, partial, off }

    @ViewBuilder
    private func verdict(headroom: CGFloat) -> some View {
        let (status, title, detail) = assess(headroom: headroom)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: status == .on ? "sun.max.fill" : status == .partial ? "sun.haze.fill" : "sun.min")
                .font(.title2)
                .foregroundStyle(status == .on ? AnyShapeStyle(Theme.accentGradient)
                                 : status == .partial ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(Color.white.opacity(0.6)))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.bold))
                Text(detail).font(.caption).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func assess(headroom: CGFloat) -> (Status, String, String) {
        let source = engine.sourceVideoFormat
        let presented = engine.videoFormat
        let boosting = headroom > 1.05
        if engine.sourceVideoCodecName == nil {
            return (.off, "Waiting for the video", "The details appear once the stream has opened.")
        }
        if source == .sdr {
            return (.off, "This source is SDR",
                    "The file itself has no HDR. Choose a source tagged HDR, HDR10+ or DV in Sources.")
        }
        if !AetherEngine.displayCapabilities.supportsHDR || presented == .sdr {
            return (.off, "HDR source, shown as SDR",
                    "This screen or the current route (AirPlay, an external display) can't show HDR, so the picture is mapped to SDR.")
        }
        if boosting {
            return (.on, "\(Self.formatName(presented)) is on",
                    "The screen is driving highlights \(Self.headroomText(headroom)) brighter than SDR white.")
        }
        return (.partial, "\(Self.formatName(presented)) is being sent",
                "The screen isn't boosting highlights at the moment. That's normal while paused, behind these controls or in a dark scene. Low Power Mode and a very high brightness setting can also limit it.")
    }

    // MARK: Layout

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.5))
            VStack(spacing: 6) { content() }
                .padding(12)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.white.opacity(0.62))
            Spacer(minLength: 12)
            Text(value).fontWeight(.semibold).multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }

    private func yesNo(_ value: Bool) -> String { value ? "Yes" : "No" }

    // MARK: Names

    static func headroomText(_ headroom: CGFloat) -> String {
        headroom <= 1.01 ? "None" : String(format: "%.1f×", headroom)
    }

    static func formatName(_ format: VideoFormat) -> String {
        switch format {
        case .sdr: return "SDR"
        case .hdr10: return "HDR10"
        case .hdr10Plus: return "HDR10+"
        case .dolbyVision: return "Dolby Vision"
        case .hlg: return "HLG"
        }
    }

    static func routeName(_ route: VideoRoute) -> String {
        switch route {
        case .loopback: return "AVPlayer (hardware)"
        case .remoteBypass: return "AVPlayer (direct HLS)"
        case .software: return "Software renderer"
        case .audio: return "Audio only"
        case .none: return "–"
        }
    }

    static func deliveryName(_ delivery: AudioDelivery) -> String {
        switch delivery {
        case .streamCopy: return "Passed through"
        case .bridged: return "Converted for playback"
        case .decoded: return "Decoded"
        case .playerManaged: return "System player"
        case .noAudioInSource: return "No audio in source"
        case .droppedNoPipeline: return "Not playable"
        case .none: return "–"
        }
    }
}

/// Reports the screen the player's window is on. On iPhone Duo the two displays are different
/// screens with different headroom, so the main screen is not necessarily the right one to ask.
private struct ScreenReader: UIViewRepresentable {
    let onChange: (UIScreen?) -> Void

    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.onChange = onChange
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: Probe, context: Context) { view.onChange = onChange }

    final class Probe: UIView {
        var onChange: ((UIScreen?) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            let screen = window?.windowScene?.screen
            DispatchQueue.main.async { [weak self] in self?.onChange?(screen) }
        }
    }
}
