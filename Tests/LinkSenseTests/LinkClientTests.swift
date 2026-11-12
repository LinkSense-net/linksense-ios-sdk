import XCTest
@testable import LinkSense

/// Verifies the SDK→server JSON shape matches what the server's
/// `.strict()` zod schema accepts. If either side changes a field name,
/// this test breaks loudly here (instead of at runtime against a real
/// deployed server).
final class LinkClientTests: XCTestCase {

    private func makeLinkJson(id: String = "link-1", metadata: Any? = nil) -> Data {
        let now = "2026-04-21T10:00:00Z"
        let dict: [String: Any] = [
            "id": id,
            "project_id": "project-1",
            "name": "Maria invite",
            "custom_path": "m",
            "full_url": "https://acme-42.linksense.net/m",
            "desktop_url": NSNull(),
            "ios_fallback_url": NSNull(),
            "android_fallback_url": NSNull(),
            "social_title": NSNull(),
            "social_description": NSNull(),
            "social_image_url": NSNull(),
            "tags": ["launch", "partner"],
            "ios_clipboard_enabled": false,
            "created_at": now,
            "updated_at": now,
        ]
        var withMetadata = dict
        if let metadata = metadata { withMetadata["metadata"] = metadata }
        return try! JSONSerialization.data(withJSONObject: withMetadata, options: [])
    }

    private func decodeSentBody<T: Decodable>(_ bytes: Data, as type: T.Type) -> T? {
        return try? JSONDecoder().decode(type, from: bytes)
    }

    func test_link_without_metadata_decodes_nil() {
        let link = try! JSONDecoder().decode(Link.self, from: makeLinkJson())
        XCTAssertNil(link.metadata)
    }

    func test_link_metadata_null_decodes_nil() {
        let link = try! JSONDecoder().decode(Link.self, from: makeLinkJson(metadata: NSNull()))
        XCTAssertNil(link.metadata)
    }

    func test_link_metadata_decodes_every_json_shape() throws {
        // Raw JSON so number formatting (1 vs 1.5) is exactly what a server sends.
        let json = """
        {"id":"link-1","project_id":"p","name":"n","custom_path":"m",
         "full_url":"https://acme-42.linksense.net/m","tags":[],
         "created_at":"2026-04-21T10:00:00Z","updated_at":"2026-04-21T10:00:00Z",
         "metadata":{"s":"hi","i":3,"d":1.5,"t":true,"f":false,"n":null,
                     "a":[1,"x",null],"o":{"nested":{"deep":2}}}}
        """
        let link = try JSONDecoder().decode(Link.self, from: Data(json.utf8))
        XCTAssertEqual(link.metadata, [
            "s": .string("hi"),
            "i": .int(3),
            "d": .double(1.5),
            "t": .bool(true),
            "f": .bool(false),
            "n": .null,
            "a": .array([.int(1), .string("x"), .null]),
            "o": .object(["nested": .object(["deep": .int(2)])]),
        ])
    }

    func test_link_metadata_round_trips_through_encode() throws {
        let value: [String: LinkMetadataValue] = ["a": .array([.double(2.5), .bool(true)]), "o": .object(["k": .int(7)])]
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode([String: LinkMetadataValue].self, from: data), value)
    }

    func test_create_sends_allowlisted_fields_only() {
        let network = MockNetworkManager()
        let link = try! JSONDecoder().decode(Link.self, from: makeLinkJson())
        network.scripted = [.success(data: link, idempotentReplay: false)]
        let client = LinkClient(network: network)

        let exp = expectation(description: "create")
        client.create(options: CreateLinkOptions(
            name: "Maria invite",
            desktopUrl: URL(string: "https://acme.com/maria"),
            slug: "maria",
            tags: ["launch"],
            iosClipboardEnabled: true
        )) { _ in exp.fulfill() }
        wait(for: [exp], timeout: 5)

        XCTAssertEqual(network.sent.count, 1)
        let json = try! JSONSerialization.jsonObject(with: network.sent[0].body!, options: []) as! [String: Any]

        XCTAssertEqual(json["name"] as? String, "Maria invite")
        XCTAssertEqual(json["desktop_url"] as? String, "https://acme.com/maria")
        XCTAssertEqual(json["slug"] as? String, "maria")
        XCTAssertEqual(json["tags"] as? [String], ["launch"])
        XCTAssertEqual(json["ios_clipboard_enabled"] as? Bool, true)

        XCTAssertNil(json["metadata"], "metadata not set in options — must not appear")
        XCTAssertNil(json["ios_fallback_url"])
        XCTAssertNil(json["android_fallback_url"])
    }

    func test_update_with_explicit_clear_encodes_json_null() {
        let network = MockNetworkManager()
        let link = try! JSONDecoder().decode(Link.self, from: makeLinkJson())
        network.scripted = [.success(data: link, idempotentReplay: false)]
        let client = LinkClient(network: network)

        var options = UpdateLinkOptions(name: .set("renamed"))
        // Explicit clear of desktop_url — encode as JSON null.
        options.desktopUrl = .clear

        let exp = expectation(description: "update")
        client.update(id: "link-1", options: options) { _ in exp.fulfill() }
        wait(for: [exp], timeout: 5)

        let json = try! JSONSerialization.jsonObject(with: network.sent[0].body!, options: []) as! [String: Any]
        XCTAssertEqual(json["name"] as? String, "renamed")
        XCTAssertTrue(json["desktop_url"] is NSNull, "desktop_url should serialize as explicit null")
        XCTAssertNil(json["tags"], "tags not in options — must not appear")
    }

    func test_update_sends_set_fields_and_omits_unchanged() {
        let network = MockNetworkManager()
        let link = try! JSONDecoder().decode(Link.self, from: makeLinkJson())
        network.scripted = [.success(data: link, idempotentReplay: false)]
        let client = LinkClient(network: network)

        let options = UpdateLinkOptions(
            tags: .set([]),
            iosClipboardEnabled: .set(false),
            ogTitle: .clear
        )

        let exp = expectation(description: "update")
        client.update(id: "link-1", options: options) { _ in exp.fulfill() }
        wait(for: [exp], timeout: 5)

        let json = try! JSONSerialization.jsonObject(with: network.sent[0].body!, options: []) as! [String: Any]
        XCTAssertEqual(Set(json.keys), ["tags", "ios_clipboard_enabled", "og_title"])
        XCTAssertEqual(json["tags"] as? [String], [])
        XCTAssertEqual(json["ios_clipboard_enabled"] as? Bool, false)
        XCTAssertTrue(json["og_title"] is NSNull)
    }

    func test_name_tags_and_clipboard_cannot_be_cleared() {
        // The server rejects null for these three, so their type has no
        // `.clear`. This exhaustive switch stops compiling if one is added.
        func encodesNull<T>(_ field: RequiredFieldUpdate<T>) -> Bool {
            switch field {
            case .unchanged, .set: return false
            }
        }
        let options = UpdateLinkOptions()
        XCTAssertFalse(encodesNull(options.name))
        XCTAssertFalse(encodesNull(options.tags))
        XCTAssertFalse(encodesNull(options.iosClipboardEnabled))
    }

    func test_delete_returns_void_on_2xx() {
        let network = MockNetworkManager()
        network.scripted = [.success(data: (), idempotentReplay: false)]
        let client = LinkClient(network: network)

        let exp = expectation(description: "delete")
        client.delete(id: "link-1") { result in
            if case .success = result {
                exp.fulfill()
            } else {
                XCTFail("expected success")
            }
        }
        wait(for: [exp], timeout: 5)
    }

    func test_forbidden_cross_scope_surfaces_as_typed_error() {
        let network = MockNetworkManager()
        network.scripted = [.failure(.forbiddenCrossScope)]
        let client = LinkClient(network: network)

        let exp = expectation(description: "update rejected")
        var options = UpdateLinkOptions(name: .set("renamed"))
        options.desktopUrl = .unchanged
        client.update(id: "link-1", options: options) { result in
            switch result {
            case .success:
                XCTFail("expected failure")
            case .failure(let err):
                XCTAssertEqual(err, .forbiddenCrossScope)
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }
}
