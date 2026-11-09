import Foundation

/// API host. Baked in at SDK build time — integrators do not configure
/// this. Internal staging builds set the `LINKSENSE_STAGING` Swift active
/// compilation condition (`swift build -Xswiftc -DLINKSENSE_STAGING` or
/// the equivalent xcconfig flag at XCFramework build time).
internal enum BaseURL {
    #if LINKSENSE_STAGING
    static let value = URL(string: "https://linksense-staging.net")!
    #else
    static let value = URL(string: "https://linksense.net")!
    #endif
}
