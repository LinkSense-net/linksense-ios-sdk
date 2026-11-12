import XCTest
@testable import LinkSense

/// Pins the server-error-code → typed-`LinkSenseError` mapping.
/// If a code string changes on the server, the right place for this test
/// to fail is here — not in production telemetry.
final class NetworkManagerErrorMappingTests: XCTestCase {

    private func envelope(code: String, message: String = "x", fieldErrors: [String: String]? = nil) -> Data {
        var error: [String: Any] = ["code": code, "message": message]
        if let fieldErrors = fieldErrors {
            // The backend's wire shape: details: [{field, message}].
            error["details"] = fieldErrors.map { ["field": $0.key, "message": $0.value] }
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

    func test_slug_codes_map_to_slugExists() {
        for code in ["CUSTOM_PATH_EXISTS", "SLUG_EXISTS"] {
            let err = NetworkManager.mapErrorResponse(
                status: 409,
                data: envelope(code: code),
                httpResponse: httpResponse(status: 409)
            )
            XCTAssertEqual(err, .slugExists, "code \(code) should map to .slugExists")
        }
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
        XCTAssertEqual(err, .rateLimited(retryAfterSeconds: 42))
    }

    func test_rate_limited_without_header_has_nil_retryAfterSeconds() {
        let err = NetworkManager.mapErrorResponse(
            status: 429,
            data: envelope(code: "RATE_LIMITED"),
            httpResponse: httpResponse(status: 429)
        )
        XCTAssertEqual(err, .rateLimited(retryAfterSeconds: nil))
    }

    private func accessDeniedBody(details: Any?) -> Data {
        var error: [String: Any] = ["code": "ACCESS_DENIED", "message": "Link limit reached"]
        if let details = details { error["details"] = details }
        return try! JSONSerialization.data(withJSONObject: ["error": error])
    }

    /// Link quota reached: `checkLinkCreationLimit` sends every field.
    func test_access_denied_with_details() {
        let body = accessDeniedBody(details: [
            "upgradeRequired": true, "plan": "starter", "currentUsage": 10, "limit": 10,
        ])
        let err = NetworkManager.mapErrorResponse(status: 403, data: body, httpResponse: httpResponse(status: 403))
        XCTAssertEqual(err, .accessDenied(AccessDeniedDetails(
            serverMessage: "Link limit reached",
            upgradeRequired: true,
            plan: "starter",
            currentUsage: 10,
            limit: 10
        )))
    }

    /// No subscription: only `upgradeRequired` and `plan`.
    func test_access_denied_with_partial_details() {
        let body = accessDeniedBody(details: ["upgradeRequired": true, "plan": "starter"])
        let err = NetworkManager.mapErrorResponse(status: 403, data: body, httpResponse: httpResponse(status: 403))
        XCTAssertEqual(err, .accessDenied(AccessDeniedDetails(
            serverMessage: "Link limit reached", upgradeRequired: true, plan: "starter"
        )))
    }

    /// Platform not allowed: `/install`, `/open`, `/deferred-match` send no details.
    func test_access_denied_without_details_defaults_upgradeRequired_false() {
        let err = NetworkManager.mapErrorResponse(
            status: 403, data: accessDeniedBody(details: nil), httpResponse: httpResponse(status: 403)
        )
        XCTAssertEqual(err, .accessDenied(AccessDeniedDetails(serverMessage: "Link limit reached")))
    }

    /// An array-shaped `details` on ACCESS_DENIED must not break the envelope.
    func test_access_denied_with_array_details_still_maps() {
        let body = accessDeniedBody(details: [["field": "x", "message": "y"]])
        let err = NetworkManager.mapErrorResponse(status: 403, data: body, httpResponse: httpResponse(status: 403))
        XCTAssertEqual(err, .accessDenied(AccessDeniedDetails(serverMessage: "Link limit reached")))
    }

    /// No body at all: there is no code to map, so it stays a generic server error.
    func test_403_with_no_body_is_a_server_error() {
        let err = NetworkManager.mapErrorResponse(status: 403, data: nil, httpResponse: httpResponse(status: 403))
        XCTAssertEqual(err, .server(code: "HTTP_403", message: "HTTP 403", status: 403))
    }

    /// An object-shaped `details` on INVALID_INPUT yields no field errors
    /// but keeps the code.
    func test_invalid_input_with_object_details_keeps_the_code() {
        let body = try! JSONSerialization.data(withJSONObject: [
            "error": ["code": "INVALID_INPUT", "message": "bad", "details": ["limit": 1]],
        ])
        let err = NetworkManager.mapErrorResponse(status: 400, data: body, httpResponse: httpResponse(status: 400))
        XCTAssertEqual(err, .invalidInput(fieldErrors: [:]))
    }
}
