import XCTest
@testable import LinkSense

/// Pins the server-error-code → typed-`LinkSenseError` mapping.
/// If a code string changes on the server, the right place for this test
/// to fail is here — not in production telemetry.
final class NetworkManagerErrorMappingTests: XCTestCase {

    private func envelope(code: String, message: String = "x", fieldErrors: [String: String]? = nil) -> Data {
        var error: [String: Any] = ["code": code, "message": message]
        if let fieldErrors = fieldErrors {
            error["fieldErrors"] = fieldErrors
        }
        return try! JSONSerialization.data(withJSONObject: ["error": error], options: [])
    }

    private func httpResponse(status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        return HTTPURLResponse(
            url: URL(string: "https://linksense.net/api/sdk/v1/links/x")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        )!
    }

    func test_unauthorized_code_maps_to_unauthorized() {
        for code in ["UNAUTHORIZED", "AUTH_REQUIRED"] {
            let err = NetworkManager.mapErrorResponse(
                status: 401,
                data: envelope(code: code),
                httpResponse: httpResponse(status: 401)
            )
            XCTAssertEqual(err, .unauthorized, "code \(code) should map to .unauthorized")
        }
    }

    func test_not_found_maps_to_notFound() {
        let err = NetworkManager.mapErrorResponse(
            status: 404,
            data: envelope(code: "NOT_FOUND"),
            httpResponse: httpResponse(status: 404)
        )
        XCTAssertEqual(err, .notFound)
    }

    func test_custom_path_exists_maps_to_customPathExists() {
        let err = NetworkManager.mapErrorResponse(
            status: 409,
            data: envelope(code: "CUSTOM_PATH_EXISTS"),
            httpResponse: httpResponse(status: 409)
        )
        XCTAssertEqual(err, .customPathExists)
    }

    func test_invalid_input_without_fieldErrors_maps_to_empty_dict() {
        let err = NetworkManager.mapErrorResponse(
            status: 400,
            data: envelope(code: "INVALID_INPUT"),
            httpResponse: httpResponse(status: 400)
        )
        XCTAssertEqual(err, .invalidInput(fieldErrors: [:]))
    }

    func test_invalid_input_with_fieldErrors_extracts_map() {
        let fieldErrors = ["name": "must not be empty", "slug": "invalid characters"]
        let err = NetworkManager.mapErrorResponse(
            status: 400,
            data: envelope(code: "INVALID_INPUT", fieldErrors: fieldErrors),
            httpResponse: httpResponse(status: 400)
        )
        XCTAssertEqual(err, .invalidInput(fieldErrors: fieldErrors))
    }

    func test_unknown_code_falls_through_to_server() {
        let err = NetworkManager.mapErrorResponse(
            status: 500,
            data: envelope(code: "SOMETHING_WEIRD", message: "boom"),
            httpResponse: httpResponse(status: 500)
        )
        XCTAssertEqual(err, .server(code: "SOMETHING_WEIRD", message: "boom", status: 500))
    }

    func test_rate_limited_reads_retry_after_header() {
        let err = NetworkManager.mapErrorResponse(
            status: 429,
            data: envelope(code: "RATE_LIMITED"),
            httpResponse: httpResponse(status: 429, headers: ["Retry-After": "42"])
        )
        XCTAssertEqual(err, .rateLimited(retryAfter: 42))
    }
}
