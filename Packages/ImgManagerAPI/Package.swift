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
            // openapi.vendored.json is the byte-identical provenance artifact (see
            // scripts/sync-openapi.sh); it is not a plugin input and is excluded so SwiftPM
            // does not try to bundle it as a resource. openapi.json (the bridged working
            // copy the plugin reads) and openapi-generator-config.yaml stay IN sources: they
            // are the plugin's declared inputs, and excluding them makes the plugin report
            // that the target has no document to generate from.
            exclude: ["openapi.vendored.json"],
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
