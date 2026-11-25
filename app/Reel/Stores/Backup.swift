import Foundation

/// One file holding everything worth keeping that isn't a credential.
enum Backup {
    private struct File: Codable {
        var app: String
        var version: Int
        var createdAt: Date
        var library: Data
        var sources: SourceMemory.Saved
        /// The settings, as a property list.
        var settings: Data
    }

    /// UserDefaults keys that belong in a backup: settings and layout, never keys or tokens
    /// (those are in the Keychain) and nothing tied to this device's state.
    private static let prefixes = [
        "debrid.service", "torrentio.", "player.", "playback.", "sources.", "subtitles.", "appearance.", "home.",
        "prefer.", "downloads.", "notify.", "browse.", "explore.", "library.", "search.", "setup.",
    ]

    @MainActor
    static func data(library: Library, memory: SourceMemory) -> Data? {
        let defaults = UserDefaults.standard.dictionaryRepresentation()
            .filter { key, _ in prefixes.contains { key.hasPrefix($0) } }
        guard let libraryData = library.exportData(),
              let settings = try? PropertyListSerialization.data(fromPropertyList: defaults, format: .binary, options: 0) else { return nil }
        let file = File(app: AppConfig.name, version: 1, createdAt: Date(), library: libraryData,
                        sources: memory.snapshot, settings: settings)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(file)
    }

    /// Writes the backup to a temporary file named for today, for the share sheet.
    @MainActor
    static func write(library: Library, memory: SourceMemory) -> URL? {
        guard let data = data(library: library, memory: memory) else { return nil }
        let day = Date().formatted(.iso8601.year().month().day())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(AppConfig.name) Backup \(day).json")
        return (try? data.write(to: url, options: .atomic)) != nil ? url : nil
    }

    @MainActor
    static func restore(_ data: Data, library: Library, memory: SourceMemory) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(File.self, from: data)
        try library.importData(file.library)
        memory.restore(file.sources)
        if let settings = try? PropertyListSerialization.propertyList(from: file.settings, format: nil) as? [String: Any] {
            for (key, value) in settings where prefixes.contains(where: { key.hasPrefix($0) }) {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
    }
}
