// swift-tools-version: 6.2
import PackageDescription

// The bottom layer: this package knows the wire format and nothing about the domain (mirrors
// memos-ng-ios's MemosAPI). "Never hand-write a client method: if something will not generate,
// fix the contract" (memos-ng-ios/CLAUDE.md:116).
let package = Package(
    name: "ImgManagerAPI",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "ImgManagerAPI", targets: ["ImgManagerAPI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.13.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.12.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.3.1"),
        .package(url: "https://github.com/apple/swift-http-types", from: "1.6.0"),
    ],
    targets: [
        .target(
            name: "ImgManagerAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            // openapi.json is vendored verbatim (scripts/sync-openapi.sh — byte-identical to
            // img-manager's frontend/openapi.json at the recorded commit, OPENAPI_SOURCE) and
            // is the plugin's declared input alongside openapi-generator-config.yaml; no
            // exclude is needed since the normalization-bridge split (openapi.vendored.json ->
            // tools/normalize-openapi.py -> openapi.json) was retired in WP8 P1-ios once
            // img-manager's P1-backend started emitting OAS 3.1 nullable type arrays natively
            // (docs/OPENAPI_NORMALIZATION_DEBT.md, closed; mirrors memos-ng-ios commit dfc2545).
            swiftSettings: [.swiftLanguageMode(.v6)],
            plugins: [
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")
            ]
        ),
        .testTarget(
            name: "ImgManagerAPITests",
            dependencies: ["ImgManagerAPI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
