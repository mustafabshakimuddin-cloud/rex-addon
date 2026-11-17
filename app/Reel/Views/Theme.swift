import SwiftUI
import UIKit
import ImageIO

enum Theme {
    static let accent = Color(red: 0.957, green: 0.420, blue: 0.659)
    static let accentDeep = Color(red: 0.46, green: 0.26, blue: 0.86)
    static let background = Color(red: 0.035, green: 0.035, blue: 0.055)
    static let surface = Color.white.opacity(0.06)
    static let secondaryText = Color.white.opacity(0.62)
    static let cached = Color(red: 0.33, green: 0.85, blue: 0.55)

    static let accentGradient = LinearGradient(colors: [accentDeep, accent], startPoint: .leading, endPoint: .trailing)

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
