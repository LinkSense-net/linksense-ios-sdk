import Foundation
@testable import LinkSense

// MARK: - Storage mock

final class InMemoryStorage: StorageManagerProtocol {
    var firstLaunchDone = false
    var deviceIdValue: String?
    var idempotencyKey: String?
    var pending: (data: Data, storedAt: Date)?
    var clipboardReadDone = false

    var idempotencyKeyGenerations = 0

    func isFirstLaunch() -> Bool { !firstLaunchDone }
    func markFirstLaunchComplete() { firstLaunchDone = true }

    func deviceID() -> String {
        if let existing = deviceIdValue { return existing }
        let fresh = UUID().uuidString
        deviceIdValue = fresh
        return fresh
    }

    func installIdempotencyKey() -> String {
        if let existing = idempotencyKey { return existing }
        idempotencyKeyGenerations += 1
        let fresh = "idempotency-test-key-\(idempotencyKeyGenerations)-aaaaaaaaaa"
        idempotencyKey = fresh
        return fresh
    }
    func clearInstallIdempotencyKey() { idempotencyKey = nil }

    func pendingInstallBody() -> (data: Data, storedAt: Date)? { pending }
    func storePendingInstallBody(_ data: Data) { pending = (data, Date()) }
    func clearPendingInstallBody() { pending = nil }

    func firstLaunchClipboardRead() -> Bool { clipboardReadDone }
    func markFirstLaunchClipboardRead() { clipboardReadDone = true }
}

// MARK: - Fingerprint mock

final class StubFingerprintCollector: FingerprintCollectorProtocol {
    var fingerprint: DeviceFingerprint

    init(fingerprint: DeviceFingerprint? = nil) {
        self.fingerprint = fingerprint ?? DeviceFingerprint(
            platform: "ios",
            model: "iPhone15,3",
            osVersion: "17.4",
            appVersion: "1.2.3",
            bundleId: "com.acme.app",
            locale: "en_US",
            language: "en-US",
            timezoneOffsetMinutes: -420,
            screenLogicalW: 390,
            screenLogicalH: 844,
            pixelRatio: 3.0,
            deviceIDSeed: "DEADBEEF-0000-0000-0000-000000000000",
            userAgent: "LinkSense/0.1.0 (com.acme.app; iPhone15,3; iOS 17.4; v1.2.3)"
        )
    }

    func collect() -> DeviceFingerprint { fingerprint }
}

// MARK: - Clipboard mock

final class StubClipboardReader: ClipboardReaderProtocol {
    var nextClickId: String?
    var readCallCount = 0

    func readDeferredClickId() -> String? {
        readCallCount += 1
        return nextClickId
    }
}

// MARK: - Network mock (records calls, returns a scripted queue of responses)

final class MockNetworkManager: NetworkManagerProtocol {
    struct SentCall {
        let endpoint: Endpoint
        let body: Data?
    }

    enum ScriptedResponse {
        case success(data: Any, idempotentReplay: Bool)
        case failure(LinkSenseError)
    }

    var sent: [SentCall] = []
    var scripted: [ScriptedResponse] = []

    func send<Request, Response>(
        endpoint: Endpoint,
        body: Request?,
        extraHeaders: [String: String],
        completion: @escaping (Result<NetworkResponse<Response>, LinkSenseError>) -> Void
    ) where Request: Encodable, Response: Decodable {
        sent.append(SentCall(endpoint: endpoint, body: body.flatMap { try? JSONEncoder().encode($0) }))
        let response = scripted.isEmpty ? ScriptedResponse.failure(.network(underlying: NSError(domain: "mock", code: 0))) : scripted.removeFirst()
        DispatchQueue.global().async {
            switch response {
            case .success(let value, let replay):
                guard let typed = value as? Response else {
                    completion(.failure(.decodeFailure(message: "scripted response type mismatch")))
                    return
                }
                completion(.success(NetworkResponse(data: typed, idempotentReplay: replay)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func sendVoid<Request>(
        endpoint: Endpoint,
        body: Request?,
        completion: @escaping (Result<Void, LinkSenseError>) -> Void
    ) where Request: Encodable {
        sent.append(SentCall(endpoint: endpoint, body: body.flatMap { try? JSONEncoder().encode($0) }))
        let response = scripted.isEmpty ? ScriptedResponse.failure(.network(underlying: NSError(domain: "mock", code: 0))) : scripted.removeFirst()
        DispatchQueue.global().async {
            switch response {
            case .success:
                completion(.success(()))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// Helper — decode the last sent body as a typed struct.
    func lastBody<T: Decodable>(as type: T.Type) -> T? {
        guard let data = sent.last?.body else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
