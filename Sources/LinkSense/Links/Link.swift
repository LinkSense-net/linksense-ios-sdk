import Foundation

/// A dynamic link resolved from the LinkSense backend.
///
/// `id` / `projectId` / `fullUrl` are always present. Per-platform
/// fallbacks and social preview fields are optional — they reflect
/// whatever the link was configured with on the dashboard or via the
/// SDK at creation time.
public struct Link: Decodable, Sendable, Equatable {
    public let id: String
    public let projectId: String
    public let name: String
    public let slug: String
    public let fullUrl: URL
    public let desktopUrl: URL?
    public let iosFallbackUrl: URL?
    public let androidFallbackUrl: URL?
    public let ogTitle: String?
    public let ogDescription: String?
    public let ogImageUrl: URL?
    public let tags: [String]
    public let iosClipboardEnabled: Bool
    public let createdAt: Date
    public let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case projectId = "project_id"
        case name
        case slug = "custom_path"
        case fullUrl = "full_url"
        case desktopUrl = "desktop_url"
        case iosFallbackUrl = "ios_fallback_url"
        case androidFallbackUrl = "android_fallback_url"
        case ogTitle = "social_title"
        case ogDescription = "social_description"
        case ogImageUrl = "social_image_url"
        case tags
        case iosClipboardEnabled = "ios_clipboard_enabled"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.projectId = try container.decode(String.self, forKey: .projectId)
        self.name = try container.decode(String.self, forKey: .name)
        self.slug = try container.decode(String.self, forKey: .slug)
        self.fullUrl = try container.decode(URL.self, forKey: .fullUrl)
        self.desktopUrl = try container.decodeIfPresent(URL.self, forKey: .desktopUrl)
        self.iosFallbackUrl = try container.decodeIfPresent(URL.self, forKey: .iosFallbackUrl)
        self.androidFallbackUrl = try container.decodeIfPresent(URL.self, forKey: .androidFallbackUrl)
        self.ogTitle = try container.decodeIfPresent(String.self, forKey: .ogTitle)
        self.ogDescription = try container.decodeIfPresent(String.self, forKey: .ogDescription)
        self.ogImageUrl = try container.decodeIfPresent(URL.self, forKey: .ogImageUrl)
        self.tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.iosClipboardEnabled = try container.decodeIfPresent(Bool.self, forKey: .iosClipboardEnabled) ?? false
        self.createdAt = try Link.decodeDate(container, key: .createdAt)
        self.updatedAt = try Link.decodeDate(container, key: .updatedAt)
    }

    private static func decodeDate(_ container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) throws -> Date {
        let raw = try container.decode(String.self, forKey: key)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: raw) {
            return parsed
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let parsed = formatter.date(from: raw) {
            return parsed
        }
        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: container,
            debugDescription: "Expected ISO 8601 date, got \(raw)"
        )
    }
}

/// Fields accepted by `LinkSense.shared.createLink(options:completion:)`.
/// Mirrors the server-side SDK allowlist (§B.1 of the mobile-SDK plan).
/// Unknown fields — including anything server-assigned like `projectId` —
/// will return `.forbiddenField` from the server.
public struct CreateLinkOptions: Sendable {
    public var name: String
    public var desktopUrl: URL?
    public var slug: String?
    public var tags: [String]?
    public var metadata: [String: LinkMetadataValue]?
    public var iosClipboardEnabled: Bool?
    public var iosFallbackUrl: URL?
    public var androidFallbackUrl: URL?
    public var ogTitle: String?
    public var ogDescription: String?
    public var ogImageUrl: URL?

    public init(
        name: String,
        desktopUrl: URL? = nil,
        slug: String? = nil,
        tags: [String]? = nil,
        metadata: [String: LinkMetadataValue]? = nil,
        iosClipboardEnabled: Bool? = nil,
        iosFallbackUrl: URL? = nil,
        androidFallbackUrl: URL? = nil,
        ogTitle: String? = nil,
        ogDescription: String? = nil,
        ogImageUrl: URL? = nil
    ) {
        self.name = name
        self.desktopUrl = desktopUrl
        self.slug = slug
        self.tags = tags
        self.metadata = metadata
        self.iosClipboardEnabled = iosClipboardEnabled
        self.iosFallbackUrl = iosFallbackUrl
        self.androidFallbackUrl = androidFallbackUrl
        self.ogTitle = ogTitle
        self.ogDescription = ogDescription
        self.ogImageUrl = ogImageUrl
    }
}

/// Tri-state for `UpdateLinkOptions` fields. Mirrors the Android SDK's
/// `FieldUpdate<T>` sealed class so the wire shape and developer mental
/// model match across platforms.
///
/// - `unchanged`: field is omitted from the PATCH body.
/// - `set(value)`: field is encoded with the new value.
/// - `clear`: field is encoded as JSON `null` (server clears it).
public enum FieldUpdate<Value: Sendable>: Sendable {
    case unchanged
    case set(Value)
    case clear
}

/// Set-or-unchanged for `UpdateLinkOptions` fields a link always has a
/// value for (`name`, `tags`, `iosClipboardEnabled`). The server rejects
/// `null` for these, so there is no `clear` case. To empty `tags`, set `[]`;
/// to turn the clipboard off, set `false`.
///
/// - `unchanged`: field is omitted from the PATCH body.
/// - `set(value)`: field is encoded with the new value.
public enum RequiredFieldUpdate<Value: Sendable>: Sendable {
    case unchanged
    case set(Value)
}

/// Fields accepted by `updateLink`. Slug is create-only — customers link
/// to the URL, so renaming would break references. Leave a field at
/// `.unchanged` to omit it, or `.set(value)` to send a new value. Optional
/// fields are `FieldUpdate<T>` and also take `.clear` (JSON null, cleared
/// server-side); `name`, `tags` and `iosClipboardEnabled` are
/// `RequiredFieldUpdate<T>` and cannot be cleared.
public struct UpdateLinkOptions: Sendable {
    public var name: RequiredFieldUpdate<String>
    public var desktopUrl: FieldUpdate<URL>
    public var tags: RequiredFieldUpdate<[String]>
    public var metadata: FieldUpdate<[String: LinkMetadataValue]>
    public var iosClipboardEnabled: RequiredFieldUpdate<Bool>
    public var iosFallbackUrl: FieldUpdate<URL>
    public var androidFallbackUrl: FieldUpdate<URL>
    public var ogTitle: FieldUpdate<String>
    public var ogDescription: FieldUpdate<String>
    public var ogImageUrl: FieldUpdate<URL>

    public init(
        name: RequiredFieldUpdate<String> = .unchanged,
        desktopUrl: FieldUpdate<URL> = .unchanged,
        tags: RequiredFieldUpdate<[String]> = .unchanged,
        metadata: FieldUpdate<[String: LinkMetadataValue]> = .unchanged,
        iosClipboardEnabled: RequiredFieldUpdate<Bool> = .unchanged,
        iosFallbackUrl: FieldUpdate<URL> = .unchanged,
        androidFallbackUrl: FieldUpdate<URL> = .unchanged,
        ogTitle: FieldUpdate<String> = .unchanged,
        ogDescription: FieldUpdate<String> = .unchanged,
        ogImageUrl: FieldUpdate<URL> = .unchanged
    ) {
        self.name = name
        self.desktopUrl = desktopUrl
        self.tags = tags
        self.metadata = metadata
        self.iosClipboardEnabled = iosClipboardEnabled
        self.iosFallbackUrl = iosFallbackUrl
        self.androidFallbackUrl = androidFallbackUrl
        self.ogTitle = ogTitle
        self.ogDescription = ogDescription
        self.ogImageUrl = ogImageUrl
    }
}

/// Values allowed in the opaque `metadata` JSON. Matches the JSON shape
/// the server accepts (≤4KB cap enforced server-side).
public enum LinkMetadataValue: Encodable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([LinkMetadataValue])
    case object([String: LinkMetadataValue])
    case null

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }
}
