import Foundation

/// Client-side SDK key format validation. Matches the server-side
/// `isValidSdkKeyFormat` in `src/features/api/sdk-key/utils.ts` — reject
/// malformed keys at `configure(_:)` time rather than letting every
/// request fail with 401.
enum SdkKeyFormat {
    static let prefix = "ls_sdk_"
    static let projectSegmentLength = 8
    static let randomSegmentLength = 32

    static func isValid(_ key: String) -> Bool {
        guard key.hasPrefix(prefix) else { return false }
        let tail = String(key.dropFirst(prefix.count))
        let expectedLength = projectSegmentLength + 1 + randomSegmentLength
        guard tail.count == expectedLength else { return false }

        let projectSegment = tail.prefix(projectSegmentLength)
        let separatorIndex = tail.index(tail.startIndex, offsetBy: projectSegmentLength)
        guard tail[separatorIndex] == "_" else { return false }
        let randomSegment = tail.suffix(randomSegmentLength)

        return isHex(projectSegment) && isHex(randomSegment)
    }

    private static func isHex(_ s: Substring) -> Bool {
        for ch in s {
            switch ch {
            case "0"..."9", "a"..."f":
                continue
            default:
                return false
            }
        }
        return true
    }
}

/// Current SDK version. Sent as `X-LinkSense-SDK-Version` on every
/// request so the backend can correlate telemetry to releases. Keep in
/// sync with the git tag when cutting a release.
enum SDKVersion {
    static let current = "0.3.0"
}
