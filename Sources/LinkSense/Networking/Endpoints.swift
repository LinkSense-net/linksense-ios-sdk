import Foundation

/// Enumeration of the `/api/sdk/v1/*` endpoints we hit. Keep this in sync
/// with `src/app/api/sdk/v1/*/route.ts` in the Next.js app — if a route
/// moves server-side, it breaks here too, which is the right signal.
enum Endpoint {
    case install
    case deferredMatch
    case open
    case createLink
    case getLink(id: String)
    case updateLink(id: String)
    case deleteLink(id: String)

    var method: String {
        switch self {
        case .install, .deferredMatch, .open, .createLink:
            return "POST"
        case .getLink:
            return "GET"
        case .updateLink:
            return "PATCH"
        case .deleteLink:
            return "DELETE"
        }
    }

    func path() -> String {
        switch self {
        case .install:
            return "/api/sdk/v1/install"
        case .deferredMatch:
            return "/api/sdk/v1/deferred-match"
        case .open:
            return "/api/sdk/v1/open"
        case .createLink:
            return "/api/sdk/v1/links"
        case .getLink(let id), .updateLink(let id), .deleteLink(let id):
            return "/api/sdk/v1/links/\(id)"
        }
    }
}
