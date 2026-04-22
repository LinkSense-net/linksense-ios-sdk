// swift-tools-version:5.9
import PackageDescription

// LinkSense iOS SDK — development manifest.
//
// Ships as source during Phase 1 development. Release builds will swap
// this for a `.binaryTarget(url:checksum:)` pointing at an XCFramework
// release asset (closed-source distribution via SPM — same model as
// AppsFlyer / Airbridge). The public-facing `Package.swift` on a tagged
// release will look like:
//
//   .binaryTarget(
//     name: "LinkSense",
//     url: "https://github.com/jankokalj/linksense-ios/releases/download/vX.Y.Z/LinkSense.xcframework.zip",
//     checksum: "<sha256>"
//   )
//
// Keep the public API surface in `Sources/LinkSense/` exactly as listed
// in the mobile-SDK plan so the binary target drop-in is transparent.
let package = Package(
    name: "LinkSense",
    // .iOS is the shipping minimum. .macOS is listed only so `swift build`
    // / `swift test` succeed on dev machines — we do not ship a macOS binary.
    platforms: [.iOS(.v14), .macOS(.v12)],
    products: [
        .library(name: "LinkSense", targets: ["LinkSense"]),
    ],
    targets: [
        .target(
            name: "LinkSense",
            path: "Sources/LinkSense",
            resources: [
                .copy("Resources/PrivacyInfo.xcprivacy"),
            ]
        ),
        .testTarget(
            name: "LinkSenseTests",
            dependencies: ["LinkSense"],
            path: "Tests/LinkSenseTests"
        ),
    ]
)
