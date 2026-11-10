import Foundation
import LinkSense

// Disambiguate from SwiftUI.Link (both types live in modules imported by ContentView).
typealias SDKLink = Link

struct LinkForm {
    var name: String = "Sample link"
    var desktopUrl: String = "https://linksense.net"
    var slug: String = ""
    var idOverride: String = ""
    var updateName: String = "Sample link (updated)"
}

enum ResultRow {
    case pending
    case ok(label: String, link: SDKLink?)
    case err(message: String)
}

@MainActor
final class SampleViewModel: ObservableObject {
    @Published var form = LinkForm()
    @Published var deferredDeepLink: URL?
    @Published var lastUniversalLink: URL?
    @Published var lastCreatedId: String?
    @Published var lastResult: ResultRow = .pending
    @Published var inFlight: Bool = false

    private func resolvedId() -> String? {
        let override = form.idOverride.trimmingCharacters(in: .whitespaces)
        if !override.isEmpty { return override }
        return lastCreatedId
    }

    func createLink() {
        guard !inFlight else { return }
        inFlight = true
        let options = CreateLinkOptions(
            name: form.name.trimmed(defaultTo: "Sample link"),
            desktopUrl: form.desktopUrl.trimmedNonEmpty().flatMap { URL(string: $0) },
            slug: form.slug.trimmedNonEmpty()
        )
        LinkSense.shared.createLink(options: options) { [weak self] result in
            guard let self else { return }
            self.inFlight = false
            switch result {
            case .success(let link):
                self.lastCreatedId = link.id
                self.lastResult = .ok(label: "created id=\(link.id)", link: link)
            case .failure(let error):
                self.lastResult = .err(message: error.userFacingMessage)
            }
        }
    }

    func getLink() {
        guard !inFlight else { return }
        guard let id = resolvedId() else {
            lastResult = .err(message: "No link id — create one first or fill 'id override'.")
            return
        }
        inFlight = true
        LinkSense.shared.getLink(id: id) { [weak self] result in
            guard let self else { return }
            self.inFlight = false
            switch result {
            case .success(let link):
                self.lastResult = .ok(label: "got id=\(id)", link: link)
            case .failure(let error):
                self.lastResult = .err(message: error.userFacingMessage)
            }
        }
    }

    func updateLink() {
        guard !inFlight else { return }
        guard let id = resolvedId() else {
            lastResult = .err(message: "No link id — create one first or fill 'id override'.")
            return
        }
        inFlight = true
        let newName = form.updateName.trimmed(defaultTo: "Sample link (updated)")
        LinkSense.shared.updateLink(id, options: UpdateLinkOptions(name: .set(newName))) { [weak self] result in
            guard let self else { return }
            self.inFlight = false
            switch result {
            case .success(let link):
                self.lastResult = .ok(label: "updated id=\(id)", link: link)
            case .failure(let error):
                self.lastResult = .err(message: error.userFacingMessage)
            }
        }
    }

    func deleteLink() {
        guard !inFlight else { return }
        guard let id = resolvedId() else {
            lastResult = .err(message: "No link id — create one first or fill 'id override'.")
            return
        }
        inFlight = true
        LinkSense.shared.deleteLink(id) { [weak self] result in
            guard let self else { return }
            self.inFlight = false
            switch result {
            case .success:
                if self.lastCreatedId == id { self.lastCreatedId = nil }
                self.lastResult = .ok(label: "deleted id=\(id)", link: nil)
            case .failure(let error):
                self.lastResult = .err(message: error.userFacingMessage)
            }
        }
    }
}

private extension String {
    func trimmed(defaultTo fallback: String) -> String {
        let t = trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? fallback : t
    }

    func trimmedNonEmpty() -> String? {
        let t = trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }
}

extension LinkSenseError {
    var userFacingMessage: String {
        switch self {
        case .notConfigured:
            return "Not configured — set LINKSENSE_SDK_KEY in Secrets.xcconfig."
        case .invalidSdkKey:
            return "SDK key format is invalid."
        case .unauthorized:
            return "401 Unauthorized — SDK key missing, malformed, or unknown."
        case .notFound:
            return "404 Not found."
        case .customPathExists:
            return "409 That slug is already in use for this project."
        case .invalidInput(let fieldErrors):
            if fieldErrors.isEmpty { return "400 Invalid input." }
            let detail = fieldErrors.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", ")
            return "400 Invalid input — \(detail)"
        case .forbiddenCrossScope:
            return "403 This SDK key cannot modify that link."
        case .forbiddenField:
            return "400 Request body contained a disallowed field."
        case .rateLimited(let retryAfter):
            if let retryAfter { return "429 Rate limited — retry after \(retryAfter)s." }
            return "429 Rate limited."
        case .network(let underlying):
            return "Network error: \(underlying.localizedDescription)"
        case .server(let code, let message, let status):
            return "Server \(status) (\(code)): \(message)"
        case .decodeFailure(let message):
            return "Decode failure: \(message)"
        }
    }
}
