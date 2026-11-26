import Foundation

/// The Movie Database, for what Cinemeta doesn't have: photos and biographies of cast and crew.
/// Optional: it needs a free key of the user's own (an API key or a read access token), kept in
/// the Keychain. Without one, people pages show initials as before.
actor TMDB {
    static let shared = TMDB()

    struct Person: Sendable, Equatable {
        let id: Int
        let name: String
        let photo: URL?
        let department: String?
        var biography: String?
        var birthday: String?
        var birthplace: String?
    }

    private var people: [String: Person?] = [:]
    private static let keychainAccount = "tmdb.key"

    static var key: String { Keychain.read(keychainAccount) ?? "" }
    static var isConfigured: Bool { !key.trimmingCharacters(in: .whitespaces).isEmpty }
    static func setKey(_ value: String) { Keychain.write(value.trimmingCharacters(in: .whitespacesAndNewlines), for: keychainAccount) }

    /// The person best matching a name, with a photo; nil without a key or a match.
    func person(named name: String, details: Bool = false) async -> Person? {
        let cacheKey = name.lowercased()
        if let cached = people[cacheKey], !details || cached?.biography != nil { return cached }
        guard Self.isConfigured,
              let search = try? await Self.get("search/person", query: ["query": name, "include_adult": "false"]),
              let results = search["results"] as? [[String: Any]],
              let best = results.first(where: { ($0["name"] as? String)?.caseInsensitiveCompare(name) == .orderedSame }) ?? results.first,
              let id = best["id"] as? Int else {
            people[cacheKey] = .some(nil)
            return nil
        }
        var person = Person(id: id, name: best["name"] as? String ?? name,
                            photo: (best["profile_path"] as? String).flatMap { URL(string: "https://image.tmdb.org/t/p/w342\($0)") },
                            department: best["known_for_department"] as? String)
        if details, let info = try? await Self.get("person/\(id)", query: [:]) {
            person.biography = (info["biography"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            person.birthday = info["birthday"] as? String
            person.birthplace = info["place_of_birth"] as? String
        }
        people[cacheKey] = person
        return person
    }

    /// Checks a key, for Settings.
    static func test(_ key: String) async -> Bool {
        (try? await get("configuration", query: [:], key: key)) != nil
    }

    /// A v3 API key goes in the query; a v4 read access token (a long JWT) as a bearer token.
    private static func get(_ path: String, query: [String: String], key: String = TMDB.key) async throws -> [String: Any] {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        var components = URLComponents(string: "https://api.themoviedb.org/3/\(path)")!
        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        let isToken = key.count > 40
        if !isToken { items.append(URLQueryItem(name: "api_key", value: key)) }
        components.queryItems = items.isEmpty ? nil : items
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        if isToken { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await HTTP.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw HTTPError.status(status, components.url!) }
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}
