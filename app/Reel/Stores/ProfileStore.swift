import Foundation
import Combine

/// Someone who watches on this device. Each has their own My List, history, resume points,
/// lists, player choices and Trakt account; the debrid service, addons and settings are shared.
struct Profile: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var symbol: String
    /// Shows only family and animation titles in lists, rows and search.
    var isKids = false

    static let defaultID = "default"
    static let symbols = ["person.fill", "star.fill", "heart.fill", "moon.fill", "flame.fill", "leaf.fill", "pawprint.fill", "gamecontroller.fill"]

    var isDefault: Bool { id == Self.defaultID }

    /// The file a per-profile store keeps: the default profile keeps the names from before
    /// profiles existed, so nothing moves.
    func file(_ base: String) -> URL {
        isDefault ? JSONFile.url("\(base).json") : JSONFile.url("\(base)-\(id).json")
    }

    /// A UserDefaults or Keychain key for this profile.
    func key(_ base: String) -> String { isDefault ? base : "\(base).\(id)" }
}

@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [Profile]
    @Published private(set) var current: Profile

    /// The current profile's key prefix, read by stores that keep small things in UserDefaults.
    nonisolated(unsafe) static var currentKeySuffix = ""

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let profiles = "profiles.list"
        static let current = "profiles.current"
    }

    init() {
        var saved = UserDefaults.standard.data(forKey: Keys.profiles)
            .flatMap { try? JSONDecoder().decode([Profile].self, from: $0) } ?? []
        if !saved.contains(where: \.isDefault) {
            saved.insert(Profile(id: Profile.defaultID, name: "Me", symbol: "person.fill"), at: 0)
        }
        profiles = saved
        let currentID = UserDefaults.standard.string(forKey: Keys.current) ?? Profile.defaultID
        current = saved.first { $0.id == currentID } ?? saved[0]
        Self.currentKeySuffix = current.isDefault ? "" : ".\(current.id)"
    }

    var hasSeveral: Bool { profiles.count > 1 }

    @discardableResult
    func add(name: String, symbol: String, isKids: Bool) -> Profile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = Profile(id: UUID().uuidString.lowercased(), name: trimmed.isEmpty ? "New Profile" : trimmed,
                              symbol: symbol, isKids: isKids)
        profiles.append(profile)
        save()
        return profile
    }

    func update(_ profile: Profile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        if current.id == profile.id { current = profile }
        save()
    }

    /// Deletes a profile and its files. The default profile stays.
    func delete(_ profile: Profile) {
        guard !profile.isDefault, profile.id != current.id else { return }
        profiles.removeAll { $0.id == profile.id }
        for base in ["library", "lists", "trakt-queue"] { try? FileManager.default.removeItem(at: profile.file(base)) }
        defaults.removeObject(forKey: profile.key("player.choices"))
        defaults.removeObject(forKey: profile.key("trakt.lastActivities"))
        Keychain.write("", for: profile.key("trakt.token"))
        save()
    }

    func select(_ profile: Profile) {
        guard let match = profiles.first(where: { $0.id == profile.id }) else { return }
        current = match
        Self.currentKeySuffix = match.isDefault ? "" : ".\(match.id)"
        defaults.set(match.id, forKey: Keys.current)
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(profiles), forKey: Keys.profiles)
    }
}
