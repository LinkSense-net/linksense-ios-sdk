import Foundation

/// Thin CRUD client over `/api/sdk/v1/links/*`. All work is deferred to
/// NetworkManager; this file exists to encapsulate the request-body
/// shaping (camelCase ↔ snake_case) and response typing.
final class LinkClient {
    private let network: NetworkManagerProtocol

    init(network: NetworkManagerProtocol) {
        self.network = network
    }

    func create(options: CreateLinkOptions, completion: @escaping (Result<Link, LinkSenseError>) -> Void) {
        let body = CreateLinkRequestBody(options: options)
        network.send(endpoint: .createLink, body: body) { (result: Result<NetworkResponse<Link>, LinkSenseError>) in
            DispatchQueue.main.async {
                completion(result.map { $0.data })
            }
        }
    }

    func get(id: String, completion: @escaping (Result<Link, LinkSenseError>) -> Void) {
        network.send(endpoint: .getLink(id: id), body: nil) { (result: Result<NetworkResponse<Link>, LinkSenseError>) in
            DispatchQueue.main.async {
                completion(result.map { $0.data })
            }
        }
    }

    func update(id: String, options: UpdateLinkOptions, completion: @escaping (Result<Link, LinkSenseError>) -> Void) {
        let body = UpdateLinkRequestBody(options: options)
        network.send(endpoint: .updateLink(id: id), body: body) { (result: Result<NetworkResponse<Link>, LinkSenseError>) in
            DispatchQueue.main.async {
                completion(result.map { $0.data })
            }
        }
    }

    func delete(id: String, completion: @escaping (Result<Void, LinkSenseError>) -> Void) {
        network.sendVoid(endpoint: .deleteLink(id: id)) { result in
            DispatchQueue.main.async { completion(result) }
        }
    }
}

// MARK: - Wire bodies

/// POST /api/sdk/v1/links body. Server-side schema is `.strict()` and
/// rejects unknown keys with 400 FORBIDDEN_FIELD — only include fields
/// the server allowlists.
private struct CreateLinkRequestBody: Encodable {
    let name: String
    let desktop_url: String?
    let slug: String?
    let tags: [String]?
    let metadata: [String: LinkMetadataValue]?
    let ios_clipboard_enabled: Bool?
    let ios_fallback_url: String?
    let android_fallback_url: String?
    let og_title: String?
    let og_description: String?
    let og_image_url: String?

    init(options: CreateLinkOptions) {
        self.name = options.name
        self.desktop_url = options.desktopUrl?.absoluteString
        self.slug = options.slug
        self.tags = options.tags
        self.metadata = options.metadata
        self.ios_clipboard_enabled = options.iosClipboardEnabled
        self.ios_fallback_url = options.iosFallbackUrl?.absoluteString
        self.android_fallback_url = options.androidFallbackUrl?.absoluteString
        self.og_title = options.ogTitle
        self.og_description = options.ogDescription
        self.og_image_url = options.ogImageUrl?.absoluteString
    }

    // `Optional.none` vs `Optional.some(nil)` semantics don't map cleanly
    // to JSON when we mean "don't send this field" vs "send JSON null".
    // The server's create schema never accepts null for these fields —
    // use `encodeIfPresent` throughout.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(desktop_url, forKey: .desktop_url)
        try c.encodeIfPresent(slug, forKey: .slug)
        try c.encodeIfPresent(tags, forKey: .tags)
        try c.encodeIfPresent(metadata, forKey: .metadata)
        try c.encodeIfPresent(ios_clipboard_enabled, forKey: .ios_clipboard_enabled)
        try c.encodeIfPresent(ios_fallback_url, forKey: .ios_fallback_url)
        try c.encodeIfPresent(android_fallback_url, forKey: .android_fallback_url)
        try c.encodeIfPresent(og_title, forKey: .og_title)
        try c.encodeIfPresent(og_description, forKey: .og_description)
        try c.encodeIfPresent(og_image_url, forKey: .og_image_url)
    }

    private enum CodingKeys: String, CodingKey {
        case name, desktop_url, slug, tags, metadata
        case ios_clipboard_enabled, ios_fallback_url, android_fallback_url
        case og_title, og_description, og_image_url
    }
}

/// PATCH body. `.unchanged` omits the field, `.set(value)` sends the new
/// value, and `FieldUpdate.clear` sends JSON null to clear the field. Matches `updateDynamicLinkSdkSchema.strict()` server-side.
private struct UpdateLinkRequestBody: Encodable {
    let options: UpdateLinkOptions

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try encodeFieldUpdate(options.name, into: &c, key: .name)
        try encodeFieldUpdate(options.desktopUrl, into: &c, key: .desktop_url, transform: { $0.absoluteString })
        try encodeFieldUpdate(options.tags, into: &c, key: .tags)
        try encodeFieldUpdate(options.metadata, into: &c, key: .metadata, transform: { $0 })
        try encodeFieldUpdate(options.iosClipboardEnabled, into: &c, key: .ios_clipboard_enabled)
        try encodeFieldUpdate(options.iosFallbackUrl, into: &c, key: .ios_fallback_url, transform: { $0.absoluteString })
        try encodeFieldUpdate(options.androidFallbackUrl, into: &c, key: .android_fallback_url, transform: { $0.absoluteString })
        try encodeFieldUpdate(options.ogTitle, into: &c, key: .og_title, transform: { $0 })
        try encodeFieldUpdate(options.ogDescription, into: &c, key: .og_description, transform: { $0 })
        try encodeFieldUpdate(options.ogImageUrl, into: &c, key: .og_image_url, transform: { $0.absoluteString })
    }

    private func encodeFieldUpdate<T, Out: Encodable>(
        _ field: FieldUpdate<T>,
        into container: inout KeyedEncodingContainer<CodingKeys>,
        key: CodingKeys,
        transform: (T) -> Out
    ) throws {
        switch field {
        case .unchanged:
            return
        case .clear:
            try container.encodeNil(forKey: key)
        case .set(let value):
            try container.encode(transform(value), forKey: key)
        }
    }

    private func encodeFieldUpdate<T: Encodable>(
        _ field: RequiredFieldUpdate<T>,
        into container: inout KeyedEncodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws {
        if case .set(let value) = field {
            try container.encode(value, forKey: key)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case name, desktop_url, tags, metadata
        case ios_clipboard_enabled, ios_fallback_url, android_fallback_url
        case og_title, og_description, og_image_url
    }
}
