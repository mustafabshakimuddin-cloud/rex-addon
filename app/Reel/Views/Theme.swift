import SwiftUI
import UIKit

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

/// Decoded images shared across the app, so scrolling back to a row doesn't reload it.
actor ImageLoader {
    static let shared = ImageLoader()
    private let cache = NSCache<NSURL, UIImage>()
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    init() { cache.countLimit = 400 }

    func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    func image(for url: URL) async -> UIImage? {
        if let image = cache.object(forKey: url as NSURL) { return image }
        if let task = inFlight[url] { return await task.value }
        let task = Task<UIImage?, Never> {
            guard let (data, _) = try? await HTTP.session.data(from: url), let image = UIImage(data: data) else { return nil }
            return await image.byPreparingForDisplay() ?? image
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }
}

struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
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
            image = await ImageLoader.shared.image(for: url)
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
            logo = await ImageLoader.shared.image(for: url)
            failed = logo == nil
        }
    }
}
