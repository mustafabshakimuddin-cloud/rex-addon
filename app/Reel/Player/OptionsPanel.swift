import SwiftUI
import AetherEngine

/// Audio, subtitles, speed and playback info in one glass panel: a side panel on wide windows, a bottom card on
/// narrow ones. Built from plain buttons rather than SwiftUI Menu, which the engine's author warns
/// rebuilds while open under a ticking playback clock.
struct OptionsPanel: View {
    enum Tab: String, CaseIterable, Identifiable, Equatable {
        case audio = "Audio", subtitles = "Subtitles", speed = "Speed", info = "Info"
        var id: String { rawValue }
    }

    @ObservedObject var model: PlayerModel
    @State var tab: Tab
    let wide: Bool
    /// Looks for subtitles on OpenSubtitles for what is playing.
    var searchOnline: () -> Void = {}
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("Options", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Button(action: close) {
                    Image(systemName: "xmark").font(.subheadline.weight(.bold)).frame(width: 18, height: 18)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Close")
            }
            ScrollView {
                VStack(spacing: 6) {
                    switch tab {
                    case .audio: audioList
                    case .subtitles: subtitleList
                    case .speed: speedList
                    case .info:
                        if let engine = model.engine { PlaybackInfoView(engine: engine) }
                    }
                }
            }
            .scrollIndicators(.hidden)
            footer
        }
        .padding(18)
        .frame(maxWidth: wide ? 400 : .infinity, maxHeight: wide ? .infinity : 460)
        .glassEffect(.regular, in: .rect(cornerRadius: 30))
        .padding(wide ? 16 : 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: wide ? .trailing : .bottom)
    }

    @ViewBuilder private var audioList: some View {
        if model.audioTracks.isEmpty {
            empty("No audio tracks reported yet.")
        }
        ForEach(model.audioTracks) { track in
            row(selected: track.id == model.activeAudio,
                title: TrackLabel.title(track),
                detail: TrackLabel.audioDetail(track),
                tags: TrackLabel.audioTags(track)) {
                model.selectAudio(track)
            }
        }
    }

    @ViewBuilder private var subtitleList: some View {
        if model.activeSubtitle != nil { timing }
        row(selected: model.activeSubtitle == nil, title: "Off", detail: nil, tags: []) {
            model.selectSubtitle(nil)
        }
        ForEach(model.subtitleTracks) { track in
            row(selected: track.id == model.activeSubtitle,
                title: TrackLabel.title(track),
                detail: TrackLabel.subtitleDetail(track),
                tags: track.isForced ? ["Forced"] : []) {
                model.selectSubtitle(track)
            }
        }
        onlineSection
    }

    /// Nudges the subtitles against the picture when a file's timing is off.
    private var timing: some View {
        HStack(spacing: 10) {
            Button { model.setSubtitleDelay(model.subtitleDelay - 0.25) } label: {
                Image(systemName: "minus").frame(width: 18, height: 18)
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Show subtitles earlier")
            VStack(spacing: 2) {
                Text("Timing").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.62))
                Text(model.subtitleDelay == 0 ? "In sync" : String(format: "%+.2f s", model.subtitleDelay))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .contentTransition(.numericText())
            }
            .frame(maxWidth: .infinity)
            .onTapGesture { model.setSubtitleDelay(0) }
            Button { model.setSubtitleDelay(model.subtitleDelay + 0.25) } label: {
                Image(systemName: "plus").frame(width: 18, height: 18)
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Show subtitles later")
        }
        .padding(10)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .animation(.snappy, value: model.subtitleDelay)
    }

    @ViewBuilder private var onlineSection: some View {
        let added = Set(model.subtitleTracks.filter(\.isExternal).map(\.name))
        let results = model.onlineSubtitles
        HStack {
            Text("ONLINE").font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.5))
            Spacer()
            if model.searchingSubtitles {
                ProgressView().controlSize(.small)
            } else if results.isEmpty {
                Button("Search OpenSubtitles", systemImage: "magnifyingglass", action: searchOnline)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.glass)
            }
        }
        .padding(.top, 10)
        // A handful per language is plenty; files of one release rarely differ.
        let grouped = Dictionary(grouping: results, by: \.language)
        ForEach(grouped.keys.sorted { Languages.name(for: $0) < Languages.name(for: $1) }, id: \.self) { language in
            ForEach(Array((grouped[language] ?? []).prefix(3).enumerated()), id: \.element.id) { index, result in
                let title = index == 0 ? Languages.name(for: language) : "\(Languages.name(for: language)) \(index + 1)"
                let name = "\(title) · OpenSubtitles"
                row(selected: false, title: title, detail: "OpenSubtitles", tags: added.contains(name) ? ["Added"] : []) {
                    model.addOnlineSubtitle(result, name: name)
                }
            }
        }
    }

    @ViewBuilder private var speedList: some View {
        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0] as [Float], id: \.self) { value in
            row(selected: abs(model.rate - value) < 0.01,
                title: value == 1 ? "Normal" : "\(value.formatted())×",
                detail: nil, tags: []) {
                model.setRate(value)
            }
        }
    }

    @ViewBuilder private var footer: some View {
        switch tab {
        case .audio:
            Text("Multichannel and Dolby Atmos tracks play in Spatial Audio with AirPods and other supported headphones. Changing track reopens the stream for a moment.")
                .font(.caption2).foregroundStyle(.white.opacity(0.6))
        case .info:
            Text("Updates every second. HDR is easiest to judge in a bright scene, such as daylight or a lamp in shot.")
                .font(.caption2).foregroundStyle(.white.opacity(0.6))
        case .subtitles, .speed:
            EmptyView()
        }
    }

    private func row(selected: Bool, title: String, detail: String?, tags: [String], action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Theme.accent : .white.opacity(0.35))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    if let detail, !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(.white.opacity(0.62)).lineLimit(2)
                    }
                    if !tags.isEmpty {
                        HStack(spacing: 5) {
                            ForEach(tags, id: \.self) { PlayerChip(text: $0, highlighted: $0 == "Dolby Atmos" || $0 == "Spatial Audio") }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(selected ? Color.white.opacity(0.12) : Color.white.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.white.opacity(0.6)).frame(maxWidth: .infinity).padding()
    }
}

/// Human labels for the engine's TrackInfo.
enum TrackLabel {
    static func title(_ track: TrackInfo) -> String {
        let language = track.language.flatMap(languageName)
        let name = track.name.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, let language, !name.localizedCaseInsensitiveContains(language) {
            return "\(language) · \(name)"
        }
        if !name.isEmpty { return name }
        return language ?? "Track \(track.id)"
    }

    static func audioDetail(_ track: TrackInfo) -> String {
        var parts = [codecName(track.codec)]
        if let layout = channels(track.channels) { parts.append(layout) }
        if track.isCommentary { parts.append("Commentary") }
        if track.isVisualImpaired { parts.append("Audio description") }
        return parts.joined(separator: " · ")
    }

    static func subtitleDetail(_ track: TrackInfo) -> String {
        var parts = [codecName(track.codec)]
        if track.isHearingImpaired { parts.append("SDH") }
        if track.isExternal { parts.append("External") }
        return parts.joined(separator: " · ")
    }

    static func audioTags(_ track: TrackInfo) -> [String] {
        var tags: [String] = []
        if track.isAtmos { tags.append("Dolby Atmos") }
        if track.isAtmos || track.channels > 2 { tags.append("Spatial Audio") }
        if track.isDefault { tags.append("Default") }
        return tags
    }

    static func channels(_ count: Int) -> String? {
        switch count {
        case ..<1: return nil
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(count) channels"
        }
    }

    static func codecName(_ codec: String) -> String {
        switch codec.lowercased() {
        case "eac3": return "Dolby Digital Plus"
        case "ac3": return "Dolby Digital"
        case "truehd": return "Dolby TrueHD"
        case "dts": return "DTS"
        case "aac": return "AAC"
        case "flac": return "FLAC"
        case "opus": return "Opus"
        case "mp3": return "MP3"
        case "subrip", "srt": return "SRT"
        case "ass", "ssa": return "ASS"
        case "webvtt": return "WebVTT"
        case "mov_text": return "Text"
        case "hdmv_pgs_subtitle": return "PGS"
        case "dvd_subtitle": return "VobSub"
        case "dvb_subtitle": return "DVB"
        default: return codec.uppercased()
        }
    }

    static func languageName(_ code: String) -> String? {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.lowercased() != "und" else { return nil }
        return Locale.current.localizedString(forLanguageCode: trimmed) ?? trimmed.uppercased()
    }
}

/// Language preferences, stored as ISO 639-2 codes; the engine matches against the tags files
/// carry, which can be either form, so both are offered.
enum Languages {
    static let options: [(String, String)] = [
        ("", "Default"),
        ("eng", "English"), ("spa", "Spanish"), ("fre", "French"), ("ger", "German"), ("ita", "Italian"),
        ("por", "Portuguese"), ("ara", "Arabic"), ("hin", "Hindi"), ("urd", "Urdu"), ("tur", "Turkish"),
        ("rus", "Russian"), ("jpn", "Japanese"), ("kor", "Korean"), ("chi", "Chinese"),
    ]

    private static let twoLetter = [
        "eng": "en", "spa": "es", "fre": "fr", "ger": "de", "ita": "it", "por": "pt", "ara": "ar",
        "hin": "hi", "urd": "ur", "tur": "tr", "rus": "ru", "jpn": "ja", "kor": "ko", "chi": "zh",
    ]
    private static let alternates = ["fre": "fra", "ger": "deu", "chi": "zho"]

    static func codes(for code: String) -> [String] {
        guard !code.isEmpty else { return [] }
        return [twoLetter[code], code, alternates[code]].compactMap { $0 }
    }
}

extension Languages {
    /// A readable name for a language code in any of the forms files and services use.
    static func name(for code: String) -> String {
        let lower = code.lowercased()
        if let match = options.first(where: { $0.0 == lower || codes(for: $0.0).contains(lower) }), !match.0.isEmpty {
            return match.1
        }
        return TrackLabel.languageName(lower) ?? code.uppercased()
    }

    /// Whether two codes name the same language ("en", "eng").
    static func matches(_ code: String, preferred: String) -> Bool {
        guard !preferred.isEmpty else { return false }
        return codes(for: preferred).contains(code.lowercased())
    }
}
