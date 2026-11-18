import Foundation
import AetherEngine

/// Opens a source the way the player would and reads what is really inside: Dolby Vision and its
/// profile, HDR10+, PQ or HLG transfer, bit depth, and whether the audio is Dolby Atmos. Release
/// names claim these often and wrongly; the bitstream does not.
enum SourceVerifier {
    static func verify(url: URL) async throws -> SourceVerification {
        try await Task.detached(priority: .utility) {
            // A UHD keyframe runs to several MB, so the byte budget is what binds; 32 MB and 20 s
            // is enough for the header, the HDR10+ scan and an Atmos decode on a debrid link.
            let limits = ProbeLimits(maxInputBytes: 32 << 20, maxPackets: 256, maxPacketBytes: 8 << 20, timeBudget: 20)
            let probe = try AetherEngine.probe(url: url, detecting: [.atmos, .hdr10Plus], limits: limits)
            return describe(probe)
        }.value
    }

    static func describe(_ probe: SourceProbe) -> SourceVerification {
        let transfer = probe.videoStreamFormat?.transfer?.lowercased() ?? ""
        let format: String
        if probe.isDolbyVision {
            format = "Dolby Vision"
        } else if probe.carriesHDR10PlusMetadata {
            format = "HDR10+"
        } else if transfer.contains("2084") {
            format = "HDR10"
        } else if transfer.contains("b67") || transfer.contains("hlg") {
            format = "HLG"
        } else {
            format = "SDR"
        }
        let audio = probe.audioTracks.first(where: \.isAtmos) ?? probe.audioTracks.first(where: \.isDefault) ?? probe.audioTracks.first
        let audioText = audio.map { track in
            [TrackLabel.codecName(track.codec), TrackLabel.channels(track.channels)].compactMap { $0 }.joined(separator: " · ")
        }
        return SourceVerification(
            videoFormat: format,
            dolbyVisionProfile: probe.isDolbyVision ? probe.dvProfile : nil,
            resolution: probe.videoWidth > 0 ? "\(probe.videoWidth)×\(probe.videoHeight)" : nil,
            bitDepth: probe.videoStreamFormat?.bitDepth,
            codec: probe.videoCodecName?.uppercased(),
            atmos: probe.audioTracks.contains(where: \.isAtmos),
            audio: audioText
        )
    }
}
