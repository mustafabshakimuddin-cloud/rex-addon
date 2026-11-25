import Foundation

/// What a debrid service says about the account behind an API key.
struct DebridAccountInfo: Codable, Equatable, Sendable {
    var username: String?
    var premium: Bool?
    var expires: Date?
    var checkedAt = Date()

    var daysLeft: Int? {
        guard let expires else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: expires).day
    }
}

enum DebridAccountError: LocalizedError {
    case refused, expired, unsupported

    var errorDescription: String? {
        switch self {
        case .refused: return "The debrid service refused the API key. Check it in Settings."
        case .expired: return "The debrid account's premium plan has ended. Renew it to stream."
        case .unsupported: return nil
        }
    }
}

/// Reads the account behind an API key from the service's own API. Unlike resolving a release,
/// this changes nothing on the account. The key is the same one Torrentio uses; nothing else is
/// asked for.
enum DebridAccount {
    static func supports(_ service: DebridService) -> Bool { request(service, key: "x") != nil }

    static func info(service: DebridService, key rawKey: String) async throws -> DebridAccountInfo {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let request = request(service, key: key) else { throw DebridAccountError.unsupported }
        let (data, response) = try await HTTP.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw DebridAccountError.refused }
        guard (200..<300).contains(status) else { throw HTTPError.status(status, request.url!) }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let info = try parse(service, json)
        if info.premium == false || (info.expires.map { $0 < Date() } ?? false) { throw DebridAccountError.expired }
        return info
    }

    static func request(_ service: DebridService, key: String) -> URLRequest? {
        func make(_ address: String, bearer: Bool) -> URLRequest? {
            guard let url = URL(string: address) else { return nil }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            if bearer { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            request.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
            return request
        }
        let encoded = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
        switch service {
        case .realdebrid: return make("https://api.real-debrid.com/rest/1.0/user", bearer: true)
        case .alldebrid: return make("https://api.alldebrid.com/v4/user?agent=\(AppConfig.name)&apikey=\(encoded)", bearer: true)
        case .premiumize: return make("https://www.premiumize.me/api/account/info?apikey=\(encoded)", bearer: false)
        case .torbox: return make("https://api.torbox.app/v1/api/user/me", bearer: true)
        case .debridlink: return make("https://debrid-link.com/api/v2/account/infos", bearer: true)
        case .putio: return make("https://api.put.io/v2/account/info", bearer: true)
        case .none, .easydebrid, .offcloud: return nil
        }
    }

    /// Each service shapes its answer differently; only what is there is read.
    static func parse(_ service: DebridService, _ json: [String: Any]) throws -> DebridAccountInfo {
        func date(_ value: Any?) -> Date? {
            if let seconds = value as? Double, seconds > 0 { return Date(timeIntervalSince1970: seconds) }
            if let seconds = value as? Int, seconds > 0 { return Date(timeIntervalSince1970: TimeInterval(seconds)) }
            if let text = value as? String { return DateParsing.parse(text) ?? DateParsing.parseDay(text) }
            return nil
        }
        func failed(_ ok: Bool) throws { if !ok { throw DebridAccountError.refused } }
        switch service {
        case .realdebrid:
            let type = json["type"] as? String
            return DebridAccountInfo(username: json["username"] as? String, premium: type.map { $0 == "premium" },
                                     expires: date(json["expiration"]))
        case .alldebrid:
            try failed((json["status"] as? String) != "error")
            let user = ((json["data"] as? [String: Any])?["user"] as? [String: Any]) ?? [:]
            return DebridAccountInfo(username: user["username"] as? String, premium: user["isPremium"] as? Bool,
                                     expires: date(user["premiumUntil"]))
        case .premiumize:
            try failed((json["status"] as? String) != "error")
            return DebridAccountInfo(username: (json["customer_id"]).map { "\($0)" }, premium: nil, expires: date(json["premium_until"]))
        case .torbox:
            try failed((json["success"] as? Bool) != false)
            let data = json["data"] as? [String: Any] ?? [:]
            return DebridAccountInfo(username: data["email"] as? String, premium: (data["plan"] as? Int).map { $0 > 0 },
                                     expires: date(data["premium_expires_at"]))
        case .debridlink:
            try failed((json["success"] as? Bool) != false)
            let value = json["value"] as? [String: Any] ?? [:]
            let left = (value["premiumLeft"] as? Double) ?? (value["premiumLeft"] as? Int).map(Double.init)
            return DebridAccountInfo(username: value["pseudo"] as? String, premium: left.map { $0 > 0 },
                                     expires: left.flatMap { $0 > 0 ? Date().addingTimeInterval($0) : nil })
        case .putio:
            let info = json["info"] as? [String: Any] ?? [:]
            return DebridAccountInfo(username: info["username"] as? String, premium: nil, expires: date(info["plan_expiration_date"]))
        case .none, .easydebrid, .offcloud:
            throw DebridAccountError.unsupported
        }
    }
}
