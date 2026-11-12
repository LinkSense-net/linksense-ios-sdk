import Foundation

/// Low-level HTTP layer. Handles:
///   * Auth header (`Bearer <sdk_key>`)
///   * `X-LinkSense-SDK-Version` header
///   * Content-Type JSON + body encoding
///   * Envelope decoding (`{ "data": T }` / `{ "error": { code, message } }`)
///   * Exponential backoff for transient failures
///   * Buffering pending `/install` retries through `StorageManagerProtocol`
///
/// Deliberately NO dependency on Alamofire / other third-party stacks —
/// the SDK is closed-source and we don't want to surprise integrators
/// with transitive deps.
protocol NetworkManagerProtocol {
    func send<Response: Decodable>(
        endpoint: Endpoint,
        body: (any Encodable)?,
        completion: @escaping (Result<NetworkResponse<Response>, LinkSenseError>) -> Void
    )

    func sendVoid(
        endpoint: Endpoint,
        completion: @escaping (Result<Void, LinkSenseError>) -> Void
    )
}

struct NetworkResponse<T: Decodable> {
    let data: T
    /// `true` when the server echoed `X-LinkSense-Idempotent-Replay: true`.
    let idempotentReplay: Bool
}

private struct SuccessEnvelope<T: Decodable>: Decodable {
    let data: T
}

private struct ErrorEnvelope: Decodable {
    let error: ErrorBody
    struct ErrorBody: Decodable {
        let code: String
        let message: String
        /// Built from the backend's `details: [{field, message}]`
        /// (`api-response.ts` / `link-service.ts` sdkSchemaError). Empty when
        /// `details` is absent or not that array.
        let fieldErrors: [String: String]
        /// Built from ACCESS_DENIED's object-shaped `details`
        /// (`{upgradeRequired, plan, currentUsage, limit}`). `nil` when
        /// `details` is absent or not an object.
        let accessDenied: AccessDeniedDetail?

        struct AccessDeniedDetail: Decodable {
            let upgradeRequired: Bool?
            let plan: String?
            let currentUsage: Int?
            let limit: Int?
        }

        private enum CodingKeys: String, CodingKey { case code, message, details }
        private struct Detail: Decodable { let field: String; let message: String }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            code = try c.decode(String.self, forKey: .code)
            message = try c.decode(String.self, forKey: .message)
            // `details` is an array or an object depending on the code. Try
            // each shape on its own so a mismatch never fails the envelope.
            let details = (try? c.decodeIfPresent([Detail].self, forKey: .details)) ?? []
            fieldErrors = Dictionary(details.map { ($0.field, $0.message) }, uniquingKeysWith: { first, _ in first })
            accessDenied = try? c.decodeIfPresent(AccessDeniedDetail.self, forKey: .details)
        }
    }
}

final class NetworkManager: NetworkManagerProtocol {
    private let sdkKey: String
    private let sdkVersion: String
    private let session: URLSession

    /// Ordered backoff schedule. Defaults to [2, 4, 8, 16, 30] seconds
    /// per §Phase 1 iOS SDK / "Threading / retries". Not used by the
    /// public `send*` API directly — AttributionResolver drives retries
    /// for `/install` using this schedule.
    static let defaultBackoffSchedule: [TimeInterval] = [2, 4, 8, 16, 30]

    /// Per-request ceiling, mirroring OkHttp's `readTimeout` on Android
    /// (`NetworkManager.kt:40-43`). `URLSession.shared` defaults to **60s**,
    /// which combined with the five-step backoff put the worst-case `/install`
    /// give-up at roughly seven minutes — long after the user has given up on
    /// the app. 15s here brings it in line with Android's ~3.
    static let requestTimeout: TimeInterval = 15

    /// Ceiling for the whole task including retries inside URLSession's own
    /// resource loading. Android's `callTimeout` equivalent.
    static let resourceTimeout: TimeInterval = 20

    init(
        sdkKey: String,
        sdkVersion: String,
        session: URLSession? = nil
    ) {
        self.sdkKey = sdkKey
        self.sdkVersion = sdkVersion
        self.session = session ?? Self.makeSession()
    }

    /// A private session rather than `.shared`: the timeouts below are ours to
    /// set, and mutating `URLSession.shared` would leak SDK policy into the
    /// host app's own networking.
    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        // We drive retries ourselves, with jitter and Retry-After — see
        // AttributionResolver.retryDelay.
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    func send<Response: Decodable>(
        endpoint: Endpoint,
        body: (any Encodable)?,
        completion: @escaping (Result<NetworkResponse<Response>, LinkSenseError>) -> Void
    ) {
        perform(endpoint: endpoint, body: body) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let (data, http)):
                let replayHeader = (http.value(forHTTPHeaderField: "X-LinkSense-Idempotent-Replay") ?? "").lowercased() == "true"
                guard let data = data, !data.isEmpty else {
                    completion(.failure(.decodeFailure(message: "empty success body")))
                    return
                }
                do {
                    let envelope = try JSONDecoder().decode(SuccessEnvelope<Response>.self, from: data)
                    completion(.success(NetworkResponse(data: envelope.data, idempotentReplay: replayHeader)))
                } catch {
                    completion(.failure(.decodeFailure(message: error.localizedDescription)))
                }
            }
        }
    }

    func sendVoid(
        endpoint: Endpoint,
        completion: @escaping (Result<Void, LinkSenseError>) -> Void
    ) {
        perform(endpoint: endpoint, body: nil) { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success: completion(.success(()))
            }
        }
    }

    // MARK: - Internal helpers

    private func perform(
        endpoint: Endpoint,
        body: (any Encodable)?,
        completion: @escaping (Result<(Data?, HTTPURLResponse), LinkSenseError>) -> Void
    ) {
        let request: URLRequest
        do {
            request = try buildRequest(endpoint: endpoint, body: body)
        } catch {
            completion(.failure(.decodeFailure(message: "encode failed: \(error.localizedDescription)")))
            return
        }

        session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(.network(underlying: error)))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(.decodeFailure(message: "no HTTPURLResponse")))
                return
            }
            if (200..<300).contains(http.statusCode) {
                completion(.success((data, http)))
            } else {
                completion(.failure(Self.mapErrorResponse(status: http.statusCode, data: data, httpResponse: http)))
            }
        }.resume()
    }

    private func buildRequest(
        endpoint: Endpoint,
        body: (any Encodable)?
    ) throws -> URLRequest {
        let url = BaseURL.value.appendingPathComponent(endpoint.path())
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method
        request.setValue("Bearer \(sdkKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(sdkVersion, forHTTPHeaderField: "X-LinkSense-SDK-Version")
        if let body = body {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            request.httpBody = try encoder.encode(body)
        }
        return request
    }

    internal static func mapErrorResponse(status: Int, data: Data?, httpResponse: HTTPURLResponse) -> LinkSenseError {
        let decoded: ErrorEnvelope? = {
            guard let data = data, !data.isEmpty else { return nil }
            return try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
        }()
        let code = decoded?.error.code ?? "HTTP_\(status)"
        let message = decoded?.error.message ?? "HTTP \(status)"
        switch code {
        case "FORBIDDEN_CROSS_SCOPE":
            return .forbiddenCrossScope
        case "FORBIDDEN_FIELD":
            return .forbiddenField
        case "RATE_LIMITED":
            let retryAfterSeconds = Int(httpResponse.value(forHTTPHeaderField: "Retry-After") ?? "")
            return .rateLimited(retryAfterSeconds: retryAfterSeconds)
        case "UNAUTHORIZED", "AUTH_REQUIRED":
            return .unauthorized
        case "NOT_FOUND":
            return .notFound
        case "CUSTOM_PATH_EXISTS", "SLUG_EXISTS":
            return .slugExists
        case "ACCESS_DENIED":
            let details = decoded?.error.accessDenied
            return .accessDenied(AccessDeniedDetails(
                serverMessage: message,
                upgradeRequired: details?.upgradeRequired ?? false,
                plan: details?.plan,
                currentUsage: details?.currentUsage,
                limit: details?.limit
            ))
        case "INVALID_INPUT":
            return .invalidInput(fieldErrors: decoded?.error.fieldErrors ?? [:])
        default:
            return .server(code: code, message: message, status: status)
        }
    }
}
