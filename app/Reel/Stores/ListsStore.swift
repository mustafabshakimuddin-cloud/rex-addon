import Foundation
import Observation
import Combine

/// A list of your own beyond My List: "Christmas films", "To watch with Sam".
struct CustomList: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var items: [MediaItem] = []
    var createdAt = Date()
}

/// Your own lists, kept in a JSON file like the library.
@MainActor
@Observable
final class ListsStore {
    private(set) var lists: [CustomList] = []

    @ObservationIgnored private var writer: SnapshotWriter

    init(fileURL: URL = JSONFile.url("lists.json")) {
        writer = SnapshotWriter(url: fileURL)
        lists = JSONFile.read([Lossy<CustomList>].self, from: fileURL)?.compactMap(\.value) ?? []
    }

    /// Loads another profile's lists.
    func load(from fileURL: URL) {
        saveNow()
        writer.waitUntilWritten()
        writer = SnapshotWriter(url: fileURL)
        lists = JSONFile.read([Lossy<CustomList>].self, from: fileURL)?.compactMap(\.value) ?? []
    }

    func list(_ id: UUID) -> CustomList? { lists.first { $0.id == id } }

    @discardableResult
    func create(_ name: String, with item: MediaItem? = nil) -> CustomList {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let list = CustomList(name: trimmed.isEmpty ? "New List" : trimmed, items: item.map { [$0] } ?? [])
        lists.append(list)
        save()
        return list
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = lists.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lists[index].name = trimmed
        save()
    }

    func delete(_ id: UUID) {
        lists.removeAll { $0.id == id }
        save()
    }

    func contains(_ item: MediaItem, in id: UUID) -> Bool {
        list(id)?.items.contains { $0.id == item.id } ?? false
    }

    /// Adds the title, or takes it off when it is already there.
    func toggle(_ item: MediaItem, in id: UUID) {
        guard let index = lists.firstIndex(where: { $0.id == id }) else { return }
        if let at = lists[index].items.firstIndex(where: { $0.id == item.id }) {
            lists[index].items.remove(at: at)
        } else {
            lists[index].items.insert(item, at: 0)
        }
        save()
    }

    /// The lists a title is on, for its page.
    func lists(containing item: MediaItem) -> [CustomList] {
        lists.filter { $0.items.contains { $0.id == item.id } }
    }

    func replaceAll(_ lists: [CustomList]) {
        self.lists = lists
        save()
    }

    private func save() {
        let snapshot = lists
        writer.schedule(after: 0.3) { try? JSONEncoder().encode(snapshot) }
    }

    func saveNow() {
        let snapshot = lists
        writer.flush { try? JSONEncoder().encode(snapshot) }
    }

    /// For tests: wait for queued writes to reach the disk.
    func waitForSave() { writer.waitUntilWritten() }
}
