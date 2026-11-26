import SwiftUI
import AetherEngine

/// Draws the engine's subtitle cues. AetherEngine decodes every format (SRT, ASS, WebVTT, PGS, DVB)
/// into cues and leaves drawing to the host, timed against `clock.sourceTime`.
struct SubtitleOverlay: View {
    var feed: SubtitleFeed
    /// Lift text above the controls while they are showing.
    var bottomInset: CGFloat
    var appearance = SubtitleAppearance()

    var body: some View {
        // Redraws only when the set of cues on screen changes, not on every clock tick.
        if !feed.visible.isEmpty {
            SubtitleLayer(cues: feed.visible, bottomInset: bottomInset, appearance: appearance)
        }
    }
}

/// How text subtitles are drawn: the reader's size, colour and backing.
struct SubtitleAppearance: Equatable {
    var scale: Double = 1
    var style: SubtitleStyle = .outline
    var color: SubtitleColor = .white
    var lift: Double = 0
    var boxOpacity: Double = 0.72
    var followsTextSize = false

    var foreground: Color {
        switch color {
        case .white: return .white
        case .yellow: return Color(red: 1, green: 0.92, blue: 0.3)
        case .cyan: return Color(red: 0.55, green: 0.95, blue: 1)
        case .green: return Color(red: 0.6, green: 1, blue: 0.6)
        case .pink: return Color(red: 1, green: 0.7, blue: 0.85)
        }
    }
}

private struct SubtitleLayer: View {
    let cues: [SubtitleCue]
    var bottomInset: CGFloat
    var appearance: SubtitleAppearance
    @ScaledMetric(relativeTo: .body) private var textSizeFactor: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(cues) { cue in
                    if case let .image(image) = cue.body {
                        imageCue(image, in: proxy.size)
                    }
                }
                ForEach(textGroups(cues), id: \.alignment) { group in
                    VStack(spacing: 4) {
                        ForEach(group.cues) { cue in textCue(cue, width: proxy.size.width) }
                    }
                    .frame(maxWidth: proxy.size.width * 0.86)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment(group.alignment))
                    .padding(.bottom, group.alignment <= 3 ? bottomInset + appearance.lift : 0)
                    .padding(.top, group.alignment >= 7 ? 24 : 0)
                    .padding(.horizontal, 16)
                }
            }
            .animation(.easeOut(duration: 0.15), value: bottomInset)
        }
        .allowsHitTesting(false)
    }

    // MARK: Text

    private struct CueGroup { let alignment: Int; let cues: [SubtitleCue] }

    /// ASS numpad alignment: 1-3 bottom, 4-6 middle, 7-9 top. Most cues carry none (bottom centre).
    private func textGroups(_ cues: [SubtitleCue]) -> [CueGroup] {
        let text = cues.filter { if case .image = $0.body { return false } else { return true } }
        let grouped = Dictionary(grouping: text) { $0.placement?.alignment ?? 2 }
        return grouped.keys.sorted().map { CueGroup(alignment: $0, cues: grouped[$0] ?? []) }
    }

    private func frameAlignment(_ numpad: Int) -> Alignment {
        switch numpad {
        case 1: return .bottomLeading
        case 3: return .bottomTrailing
        case 4: return .leading
        case 5: return .center
        case 6: return .trailing
        case 7: return .topLeading
        case 8: return .top
        case 9: return .topTrailing
        default: return .bottom
        }
    }

    @ViewBuilder
    private func textCue(_ cue: SubtitleCue, width: CGFloat) -> some View {
        let size = min(max(width * 0.034, 17), 34)
        Group {
            switch cue.body {
            case let .text(string):
                Text(Self.clean(string))
            case let .richText(runs):
                // Text interpolation joins the styled runs; `+` on Text is deprecated.
                runs.reduce(Text(verbatim: "")) { result, run in Text("\(result)\(styled(run))") }
            case .image:
                EmptyView()
            }
        }
        .font(.system(size: size * appearance.scale * (appearance.followsTextSize ? min(textSizeFactor, 2) : 1), weight: .semibold))
        .foregroundStyle(appearance.foreground)
        .multilineTextAlignment(.center)
        .modifier(SubtitleBacking(style: appearance.style, boxOpacity: appearance.boxOpacity))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func styled(_ run: SubtitleTextRun) -> Text {
        var text = Text(Self.clean(run.text))
        if run.isBold { text = text.bold() }
        if run.isItalic { text = text.italic() }
        if run.isUnderlined { text = text.underline() }
        if run.isStruckThrough { text = text.strikethrough() }
        return text
    }

    /// Libavcodec hands text over as ASS events: hard line breaks arrive as \N.
    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: " ")
    }

    // MARK: Bitmaps

    /// Bitmap positions are normalized to the subtitle canvas, which maps onto the picture: fit the
    /// canvas into the view the way the video is fitted, then place the bitmap inside it.
    @ViewBuilder
    private func imageCue(_ image: SubtitleImage, in size: CGSize) -> some View {
        let canvas = image.canvasSize
        let scale = canvas.width > 0 && canvas.height > 0 ? min(size.width / canvas.width, size.height / canvas.height) : 1
        let shown = CGSize(width: canvas.width * scale, height: canvas.height * scale)
        let origin = CGPoint(x: (size.width - shown.width) / 2, y: (size.height - shown.height) / 2)
        let frame = CGRect(
            x: origin.x + image.position.minX * shown.width,
            y: origin.y + image.position.minY * shown.height,
            width: image.position.width * shown.width,
            height: image.position.height * shown.height
        )
        Image(decorative: image.cgImage, scale: 1)
            .resizable()
            .frame(width: max(1, frame.width), height: max(1, frame.height))
            .position(x: frame.midX, y: frame.midY)
    }
}

private struct SubtitleBacking: ViewModifier {
    let style: SubtitleStyle
    var boxOpacity: Double = 0.72

    func body(content: Content) -> some View {
        switch style {
        case .outline:
            // A soft outline reads on any picture, bright or dark.
            content
                .shadow(color: .black, radius: 0.5, x: 0, y: 0)
                .shadow(color: .black.opacity(0.9), radius: 2, x: 0, y: 1)
                .shadow(color: .black.opacity(0.6), radius: 6)
        case .shadow:
            content.shadow(color: .black.opacity(0.85), radius: 3, x: 1.5, y: 2)
        case .box:
            content
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.black.opacity(boxOpacity), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}
