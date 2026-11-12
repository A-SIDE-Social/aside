import Foundation

struct WidgetSource: Codable, Hashable {
    let id: String
    let name: String
    let kind: String
    let targetId: String
    let ownerId: String

    var selectionId: String { "\(ownerId)|\(kind)|\(targetId)" }
    var isValid: Bool {
        UUID(uuidString: ownerId) != nil && UUID(uuidString: targetId) != nil &&
        (kind == "friend" || kind == "list") && !name.isEmpty
    }
}

struct WidgetSources: Codable {
    let ownerId: String
    let sources: [WidgetSource]
}

struct WidgetSession: Equatable, Codable {
    let userId: String
    let token: String
    let baseURL: URL

    init?(userId: String?, token: String?, baseURL: String?) {
        guard let userId, UUID(uuidString: userId) != nil,
              let token, !token.isEmpty, let baseURL, let url = URL(string: baseURL),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              let host = url.host,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1"].contains(host)) else { return nil }
        self.userId = userId; self.token = token; self.baseURL = url
    }

    func endpoint(source: WidgetSource?) -> URL? {
        if let source, !source.isValid || source.ownerId != userId { return nil }
        var parts = URLComponents(url: baseURL.appendingPathComponent("v1/feed/widget"), resolvingAgainstBaseURL: false)!
        if let source {
            parts.queryItems = [URLQueryItem(name: source.kind == "friend" ? "user_id" : "group_id", value: source.targetId)]
        }
        return parts.url
    }
}

struct WidgetPhoto: Decodable {
    let id: String
    let user_id: String
    let display_name: String
    let image_url: String
    let expires_at: String?

    func expiration(now: Date) -> Date {
        let ceiling = now.addingTimeInterval(24 * 60 * 60)
        guard let value = expires_at else { return ceiling }
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expires = format.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        // An unreadable expiry must not become an indefinitely visible photo.
        return min(ceiling, expires ?? now)
    }

    func deepLink(ownerId: String) -> URL? {
        guard UUID(uuidString: id) != nil, UUID(uuidString: ownerId) != nil else { return nil }
        var parts = URLComponents()
        parts.scheme = "aside"; parts.host = "post"; parts.path = "/\(id)"
        parts.queryItems = [URLQueryItem(name: "account", value: ownerId)]
        return parts.url
    }
}

struct WidgetResponse: Decodable { let post: WidgetPhoto? }

struct WidgetStore {
    static let groupId = "group.com.lab1908.instadamn"
    let container: URL

    func read(_ key: String) -> String? {
        guard let value = try? String(contentsOf: container.appendingPathComponent("\(key).txt"), encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }
    var session: WidgetSession? {
        guard let data = try? Data(contentsOf: container.appendingPathComponent("widget_session.json")),
              let saved = try? JSONDecoder().decode(WidgetSession.self, from: data) else { return nil }
        return WidgetSession(userId: saved.userId, token: saved.token, baseURL: saved.baseURL.absoluteString)
    }
    func sources(for session: WidgetSession) -> [WidgetSource] {
        guard let data = try? Data(contentsOf: container.appendingPathComponent("widget_sources.json")),
              let cache = try? JSONDecoder().decode(WidgetSources.self, from: data),
              cache.ownerId == session.userId else { return [] }
        return cache.sources.filter { $0.isValid && $0.ownerId == session.userId }
    }
    func clearWidgetData() {
        for name in ["widget_image.jpg", "widget_meta.json", "widget_sources.json"] {
            try? FileManager.default.removeItem(at: container.appendingPathComponent(name))
        }
    }
}
