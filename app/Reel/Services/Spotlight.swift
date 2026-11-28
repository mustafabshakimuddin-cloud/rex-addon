import Foundation
#if os(iOS)
import CoreSpotlight
import UniformTypeIdentifiers
#endif

/// Puts My List in Spotlight, so a title can be found from the Home Screen's search.
enum Spotlight {
    private static let domain = "community.reel.mylist"

    static func index(_ items: [MediaItem]) {
        #if os(iOS)
        let index = CSSearchableIndex.default()
        let entries = items.map { item -> CSSearchableItem in
            let attributes = CSSearchableItemAttributeSet(contentType: .movie)
            attributes.title = item.name
            attributes.contentDescription = [item.kind.singular, item.year].compactMap { $0 }.joined(separator: " · ")
                + (item.overview.map { "\n" + $0 } ?? "")
            attributes.thumbnailURL = item.poster
            let identifier = "reel://title/\(item.id)?type=\(item.kind.rawValue)"
            return CSSearchableItem(uniqueIdentifier: identifier, domainIdentifier: domain, attributeSet: attributes)
        }
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
            guard !entries.isEmpty else { return }
            index.indexSearchableItems(entries) { _ in }
        }
        #endif
    }
}
