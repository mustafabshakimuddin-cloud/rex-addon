import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import ImageIO

/// The accent colours offered under Settings → Appearance. Each pairs a bright accent with a deeper
/// partner for gradients and the backdrop's bloom.
enum AccentChoice: String, CaseIterable, Identifiable, Codable {
    case rose, violet, ocean, mint, amber, crimson

    var id: String { rawValue }
    var title: String {
        switch self {
        case .rose: return "Rose"
        case .violet: return "Violet"
        case .ocean: return "Ocean"
        case .mint: return "Mint"
        case .amber: return "Amber"
        case .crimson: return "Crimson"
        }
    }

    var accent: Color {
        switch self {
        case .rose: return Color(red: 0.957, green: 0.420, blue: 0.659)
        case .violet: return Color(red: 0.66, green: 0.52, blue: 1.0)
        case .ocean: return Color(red: 0.30, green: 0.66, blue: 1.0)
        case .mint: return Color(red: 0.30, green: 0.86, blue: 0.70)
        case .amber: return Color(red: 1.0, green: 0.70, blue: 0.28)
        case .crimson: return Color(red: 1.0, green: 0.36, blue: 0.38)
        }
    }

    var deep: Color {
        switch self {
        case .rose: return Color(red: 0.46, green: 0.26, blue: 0.86)
        case .violet: return Color(red: 0.32, green: 0.20, blue: 0.78)
        case .ocean: return Color(red: 0.16, green: 0.26, blue: 0.80)
        case .mint: return Color(red: 0.08, green: 0.45, blue: 0.55)
        case .amber: return Color(red: 0.85, green: 0.30, blue: 0.20)
        case .crimson: return Color(red: 0.55, green: 0.10, blue: 0.40)
        }
    }
}

enum Theme {
    /// Set from AppSettings as it loads and whenever the choice changes; RootView rebuilds its tabs
    /// when it does, so every view reads the new colour.
    nonisolated(unsafe) static var choice: AccentChoice = .rose

    static var accent: Color { choice.accent }
    static var accentDeep: Color { choice.deep }
    static let background = Color(red: 0.035, green: 0.035, blue: 0.055)
    static let surface = Color.white.opacity(0.06)
    static let secondaryText = Color.white.opacity(0.62)
    static let cached = Color(red: 0.33, green: 0.85, blue: 0.55)
    static let warning = Color.orange
    static let problem = Color(red: 1.0, green: 0.33, blue: 0.33)
    /// The red dot that marks something waiting on you.
    static let attention = Color(red: 1.0, green: 0.27, blue: 0.27)

    static var accentGradient: LinearGradient { LinearGradient(colors: [accentDeep, accent], startPoint: .leading, endPoint: .trailing) }

    /// The app's backdrop: near-black with a faint violet bloom, so glass has something to refract.
    struct Backdrop: View {
        var body: some View {
            ZStack {
                Theme.background
                RadialGradient(colors: [Theme.accentDeep.opacity(0.22), .clear], center: .topLeading, startRadius: 0, endRadius: 700)
                RadialGradient(colors: [Theme.accent.opacity(0.10), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 600)
            }
            .ignoresSafeArea()
        }
    }
}

// MARK: - Images

/// Decoded images, shared across the app. Two rules keep memory flat however far you scroll:
/// images are decoded at the size they are shown at (ImageIO thumbnailing, which never holds the
/// full-size bitmap; a 1920x1080 backdrop is about 8 MB decoded), and the cache is charged by
/// decoded bytes, not by count. Decoding runs off the actor so images decode in parallel.
actor ImageLoader {
    static let shared = ImageLoader()
    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    init() {
        cache.totalCostLimit = 150 << 20   // ~150 MB of decoded pixels; NSCache also sheds under memory pressure
    }

    func image(for url: URL, maxPixelSize: Int) async -> UIImage? {
        // Bucket the size so slightly different layouts share one decode.
        let bucket = max(64, ((maxPixelSize + 127) / 128) * 128)
        let key = "\(url.absoluteString)#\(bucket)"
        if let image = cache.object(forKey: key as NSString) { return image }
        if let task = inFlight[key] { return await task.value }
        let task = Task.detached(priority: .utility) { () -> UIImage? in
            guard let (data, _) = try? await HTTP.session.data(from: url) else { return nil }
            return Self.downsample(data, maxPixelSize: bucket)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image, let cg = image.cgImage {
            cache.setObject(image, forKey: key as NSString, cost: cg.bytesPerRow * cg.height)
        }
        return image
    }

    /// Starts decoding pictures about to scroll into view, at the size they'll be drawn, so a
    /// shelf's later posters are ready when they arrive. Skips what is cached or on its way.
    func prefetch(_ urls: [URL], maxPixelSize: Int) {
        for url in urls.prefix(24) {
            let bucket = max(64, ((maxPixelSize + 127) / 128) * 128)
            let key = "\(url.absoluteString)#\(bucket)"
            guard cache.object(forKey: key as NSString) == nil, inFlight[key] == nil else { continue }
            Task(priority: .background) { _ = await self.image(for: url, maxPixelSize: maxPixelSize) }
        }
    }

    nonisolated static func downsample(_ data: Data, maxPixelSize: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,      // decode here, not on the main thread at draw time
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: image)
    }
}

extension View {
    /// Decodes the posters of a row ahead of scrolling, at the width the cards draw them.
    func prefetchPosters(_ items: [MediaItem], width: CGFloat) -> some View {
        modifier(PosterPrefetch(urls: items.compactMap(\.poster), width: width))
    }
}

private struct PosterPrefetch: ViewModifier {
    let urls: [URL]
    let width: CGFloat
    @Environment(\.displayScale) private var scale

    func body(content: Content) -> some View {
        content.task(id: urls) {
            // RemoteImage asks for the same size, so these land in the same cache entries.
            let pixels = min(Int(width * scale * 1.5), 2400)
            await ImageLoader.shared.prefetch(urls, maxPixelSize: pixels)
        }
    }
}

struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    /// The widest this image is drawn, in points; it is decoded at that size times the screen scale.
    var targetWidth: CGFloat = 400
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                Rectangle().fill(Theme.surface)
            }
        }
        .animation(.easeOut(duration: 0.25), value: image != nil)
        .task(id: url) {
            guard let url else { image = nil; return }
            // Posters are taller than wide, so the long side is ~1.5x the width; backdrops are wider.
            let pixels = Int(targetWidth * scale * 1.5)
            image = await ImageLoader.shared.image(for: url, maxPixelSize: min(pixels, 2400))
        }
    }
}

/// A title's logo artwork when Cinemeta has one, otherwise its name in large type.
struct TitleLogo: View {
    let item: MediaItem
    var maxHeight: CGFloat = 90
    @State private var logo: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let logo {
                Image(uiImage: logo).resizable().scaledToFit().frame(maxHeight: maxHeight, alignment: .leading)
                    .shadow(color: .black.opacity(0.5), radius: 12)
            } else if failed || item.logo == nil {
                Text(item.name)
                    .font(.system(size: maxHeight * 0.42, weight: .heavy, design: .rounded))
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .shadow(color: .black.opacity(0.6), radius: 10)
            } else {
                Color.clear.frame(height: maxHeight * 0.6)
            }
        }
        .task(id: item.logo) {
            guard let url = item.logo else { return }
            logo = await ImageLoader.shared.image(for: url, maxPixelSize: 900)
            failed = logo == nil
        }
    }
}
