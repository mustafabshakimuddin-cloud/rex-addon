import SwiftUI
import AetherEngine

// MARK: - Chapters

/// What a chapter's name says it is. Releases from most groups name the parts a viewer skips.
enum ChapterKind {
    case intro, recap, credits, other

    init(_ name: String) {
        let lower = name.lowercased()
        func has(_ pattern: String) -> Bool { lower.range(of: pattern, options: .regularExpression) != nil }
        if has(#"\b(recap|previously)\b"#) { self = .recap }
        else if has(#"\b(intro|opening|op|title sequence|main title)\b"#) { self = .intro }
        else if has(#"\b(credits|ending|ed|outro|end titles)\b"#) { self = .credits }
        else { self = .other }
    }

    var skipTitle: String? {
        switch self {
        case .intro: return "Skip Intro"
        case .recap: return "Skip Recap"
        case .credits: return "Skip Credits"
        case .other: return nil
        }
    }
}

extension Array where Element == ChapterInfo {
    /// Where the end credits begin, if a chapter says so and it sits in the last third.
    func creditsStart(duration: Double) -> Double? {
        guard duration > 0 else { return nil }
        return last { ChapterKind($0.name) == .credits && $0.startSeconds > duration * 0.66 }?.startSeconds
    }
}

/// "Skip Intro", shown while the playhead is inside a chapter named as one.
struct SkipChapterButton: View {
    @ObservedObject var time: PlaybackTime
    let chapters: [ChapterInfo]
    let duration: Double
    /// Credits are left to Up Next when there is a next episode.
    let skipsCredits: Bool
    let skip: (Double) -> Void

    var body: some View {
        let now = time.currentTime
        let chapter = chapters.first { chapter in
            let end = chapter.startSeconds + chapter.durationSeconds
            return now >= chapter.startSeconds + 1 && now < end - 3
        }
        let kind = chapter.map { ChapterKind($0.name) } ?? .other
        if let chapter, let title = kind.skipTitle, kind != .credits || skipsCredits {
            Button {
                skip(min(chapter.startSeconds + chapter.durationSeconds, max(duration - 1, 0)))
            } label: {
                Label(title, systemImage: "forward.end.fill")
                    .font(.headline)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glass)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }
}

// MARK: - Up Next

/// Near the end of an episode: the next one, with a countdown when autoplay is on.
struct UpNextCard: View {
    @ObservedObject var time: PlaybackTime
    let next: Episode
    let showName: String
    let startsAt: Double
    let countdown: Bool
    let isPlaying: Bool
    let playNext: () -> Void
    @State private var dismissed = false
    @State private var remaining = 10

    var body: some View {
        let visible = !dismissed && time.currentTime >= startsAt
        if visible {
            HStack(spacing: 14) {
                RemoteImage(url: next.thumbnail, targetWidth: 120)
                    .frame(width: 128, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("UP NEXT").font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.6))
                    Text("\(next.code) · \(next.title)").font(.subheadline.weight(.semibold)).lineLimit(2)
                    HStack(spacing: 8) {
                        Button(action: playNext) {
                            Label(countdown ? "Play in \(remaining)" : "Play Now", systemImage: "play.fill")
                                .font(.subheadline.weight(.bold))
                                .contentTransition(.numericText())
                        }
                        .buttonStyle(.glassProminent)
                        Button("Cancel") { dismissed = true }
                            .font(.subheadline.weight(.semibold))
                            .buttonStyle(.glass)
                    }
                }
            }
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
            .frame(maxWidth: 420)
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .task(id: isPlaying) {
                guard countdown, isPlaying else { return }
                while remaining > 0 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled || dismissed { return }
                    withAnimation { remaining -= 1 }
                }
                playNext()
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Up next: \(showName) \(next.code), \(next.title)")
        }
    }
}

// MARK: - Scrub preview

/// The frame under the finger while scrubbing, from the engine's own decoded segments.
struct ScrubPreview: View {
    let seconds: Double
    let provider: (Double) async -> CGImage?
    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.5))
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            .frame(width: 176, height: 99)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.25), lineWidth: 1))
            Text(PlayerView.clock(seconds))
                .font(.caption.weight(.bold).monospacedDigit())
                .padding(.horizontal, 8).padding(.vertical, 3)
                .glassEffect(.regular, in: .capsule)
        }
        // One decode per two-second step of the finger, and only once it pauses for a moment.
        .task(id: Int(seconds / 2)) {
            try? await Task.sleep(nanoseconds: 70_000_000)
            guard !Task.isCancelled else { return }
            if let frame = await provider(seconds), !Task.isCancelled { image = frame }
        }
        .allowsHitTesting(false)
    }
}
