import XCTest
@testable import WidgetCore

final class WidgetStateTests: XCTestCase {
    let owner = "00000000-0000-0000-0000-000000000001"
    let other = "00000000-0000-0000-0000-000000000002"
    func testSourceCannotCrossAccountsOrChangeEndpoint() throws {
        let session = try XCTUnwrap(WidgetSession(userId: owner, token: "test", baseURL: "https://example.test"))
        let friend = WidgetSource(id: other, name: "Friend", kind: "friend", targetId: other, ownerId: owner)
        XCTAssertEqual(session.endpoint(source: friend)?.path, "/v1/feed/widget")
        XCTAssertEqual(URLComponents(url: session.endpoint(source: friend)!, resolvingAgainstBaseURL: false)?.queryItems?.first?.name, "user_id")
        XCTAssertNil(session.endpoint(source: WidgetSource(id: owner, name: "Old", kind: "friend", targetId: owner, ownerId: other)))
        XCTAssertNil(session.endpoint(source: WidgetSource(id: other, name: "Bad", kind: "unknown", targetId: other, ownerId: owner)))
        XCTAssertNil(WidgetSession(userId: owner, token: "test", baseURL: "https://secret@example.test"))
        XCTAssertNil(WidgetSession(userId: owner, token: "test", baseURL: "http://example.test"))
    }
    func testExpiryIsBoundedAndInvalidExpiryFailsClosed() {
        let now = Date(timeIntervalSince1970: 0)
        func photo(_ expiry: String?) -> WidgetPhoto { WidgetPhoto(id: other, user_id: other, display_name: "Friend", image_url: "https://example.test/photo", expires_at: expiry) }
        XCTAssertEqual(photo(nil).expiration(now: now), now.addingTimeInterval(900))
        XCTAssertEqual(photo("1970-01-01T00:05:00.000Z").expiration(now: now), now.addingTimeInterval(300))
        XCTAssertEqual(photo("bad").expiration(now: now), now)
        XCTAssertEqual(photo(nil).deepLink(ownerId: owner)?.host, "post")
        XCTAssertTrue(photo(nil).deepLink(ownerId: owner)!.absoluteString.contains("account="))
    }
    func testSignOutClearsImagesAndCachedSources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WidgetStore(container: root)
        for name in ["widget_image.jpg", "widget_meta.json", "widget_sources.json"] {
            try Data("private".utf8).write(to: root.appendingPathComponent(name))
        }
        store.clearWidgetData()
        for name in ["widget_image.jpg", "widget_meta.json", "widget_sources.json"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path))
        }
    }
}
