import TVServices

/// The row the Apple TV Home Screen shows above Reel when it is in the top row: Continue
/// Watching and the next episodes, read from the file the app writes into the app group (the
/// same one the iPhone widgets read). Without it, the static Top Shelf image shows.
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        guard let data = WidgetData.load() else { return completionHandler(nil) }
        var sections: [TVTopShelfItemCollection<TVTopShelfSectionedItem>] = []
        if !data.continueWatching.isEmpty {
            let section = TVTopShelfItemCollection(items: data.continueWatching.map(Self.item))
            section.title = NSLocalizedString("Continue Watching", comment: "")
            sections.append(section)
        }
        if !data.upcoming.isEmpty {
            let section = TVTopShelfItemCollection(items: data.upcoming.map(Self.item))
            section.title = NSLocalizedString("Next Episodes", comment: "")
            sections.append(section)
        }
        completionHandler(sections.isEmpty ? nil : TVTopShelfSectionedContent(sections: sections))
    }

    private static func item(_ entry: WidgetData.Entry) -> TVTopShelfSectionedItem {
        let item = TVTopShelfSectionedItem(identifier: entry.id)
        item.title = "\(entry.title) · \(entry.subtitle)"
        item.imageShape = .hdtv
        if let url = WidgetData.imageURL(entry.image) {
            item.setImageURL(url, for: .screenScale1x)
            item.setImageURL(url, for: .screenScale2x)
        }
        if let fraction = entry.fraction { item.playbackProgress = fraction }
        item.displayAction = TVTopShelfAction(url: entry.link)
        item.playAction = TVTopShelfAction(url: entry.link)
        return item
    }
}
