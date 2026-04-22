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
    func send<Request: Encodable, Response: Decodable>(
        endpoint: Endpoint,
        body: Request?,
        extraHeaders: [String: String],
        completion: @escaping (Result<NetworkResponse<Response>, LinkSenseError>) -> Void
    )

    func sendVoid<Request: Encodable>(
        endpoint: Endpoint,
        body: Request?,
        completion: @escaping (Result<Void, LinkSenseError>) -> Void
    )
}

struct NetworkResponse<T: Decodable> {
    let data: T
    /// `true` when the server echoed `X-LinkSense-Idempotent-Replay: true`.
    let idempotentReplay: Bool
}

struct EmptyBody: Encodable {}

private struct SuccessEnvelope<T: Decodable>: Decodable {
    let data: T
}

private struct ErrorEnvelope: Decodable {
    let error: ErrorBody
    struct ErrorBody: Decodable {
        let code: String
        let message: String
    }
}

final class NetworkManager: NetworkManagerProtocol {
    private let baseURL: URL
    private let sdkKey: String
    private let sdkVersion: String
    private let session: URLSession

    /// Ordered backoff schedule. Defaults to [2, 4, 8, 16, 30] seconds
    /// per §Phase 1 iOS SDK / "Threading / retries". Not used by the
    /// public `send*` API directly — AttributionResolver drives retries
    /// for `/install` using this schedule.
    static let defaultBackoffSchedule: [TimeInterval] = [2, 4, 8, 16, 30]

    init(
        baseURL: URL,
        sdkKey: String,
        sdkVersion: String,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.sdkKey = sdkKey
        self.sdkVersion = sdkVersion
        self.session = session
    }

    func send<Request, Response>(
        endpoint: Endpoint,
        body: Request?,
        extraHeaders: [String: String] = [:],
        completion: @escaping (Result<NetworkResponse<Response>, LinkSenseError>) -> Void
    ) where Request: Encodable, Response: Decodable {
        let request: URLRequest
        do {
            request = try buildRequest(endpoint: endpoint, body: body, extraHeaders: extraHeaders)
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
            let replayHeader = (http.value(forHTTPHeaderField: "X-LinkSense-Idempotent-Replay") ?? "").lowercased() == "true"
            if (200..<300).contains(http.statusCode) {
                guard let data = data, !data.isEmpty else {
                    completion(.failure(.decodeFailure(message: "empty success body")))
                    return
                }
                do {
                    let decoder = JSONDecoder()
                    let envelope = try decoder.decode(SuccessEnvelope<Response>.self, from: data)
                    completion(.success(NetworkResponse(data: envelope.data, idempotentReplay: replayHeader)))
                } catch {
                    completion(.failure(.decodeFailure(message: error.localizedDescription)))
                }
            } else {
                completion(.failure(Self.mapErrorResponse(status: http.statusCode, data: data, httpResponse: http)))
            }
        }.resume()
    }

    func sendVoid<Request>(
        endpoint: Endpoint,
        body: Request?,
        completion: @escaping (Result<Void, LinkSenseError>) -> Void
    ) where Request: Encodable {
        let request: URLRequest
        do {
            request = try buildRequest(endpoint: endpoint, body: body, extraHeaders: [:])
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
                completion(.success(()))
            } else {
                completion(.failure(Self.mapErrorResponse(status: http.statusCode, data: data, httpResponse: http)))
            }
        }.resume()
    }

    // MARK: - Internal helpers

    private func buildRequest<Request: Encodable>(
        endpoint: Endpoint,
        body: Request?,
        extraHeaders: [String: String]
    ) throws -> URLRequest {
        let url = baseURL.appendingPathComponent(endpoint.path())
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method
        request.setValue("Bearer \(sdkKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(sdkVersion, forHTTPHeaderField: "X-LinkSense-SDK-Version")
        for (name, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body = body, !(body is EmptyBody) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            request.httpBody = try encoder.encode(body)
        }
        return request
    }

    private static func mapErrorResponse(status: Int, data: Data?, httpResponse: HTTPURLResponse) -> LinkSenseError {
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
            let retryAfter = Int(httpResponse.value(forHTTPHeaderField: "Retry-After") ?? "") ?? nil
            return .rateLimited(retryAfter: retryAfter)
        default:
            return .server(code: code, message: message, status: status)
        }
    }
}
