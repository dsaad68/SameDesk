// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SameDesk",
    platforms: [
        // macOS 14+ is required: the virtual-display path and several
        // ScreenCaptureKit / VideoToolbox conveniences need Sonoma.
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SameDesk", targets: ["SameDesk"])
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "SameDesk",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdTLS", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
            ],
            path: "Sources/SameDesk",
            // Browser client served verbatim from the bundle (loaded via
            // Bundle.module). Authored as real .html/.js for proper tooling.
            resources: [
                .copy("Client/client.html"),
                .copy("Client/client.js"),
            ],
            // App Sandbox is intentionally DISABLED (see README §Security): we
            // need CGEvent injection on the .cghidEventTap and unrestricted
            // network binding. Do not add sandbox/hardened-runtime entitlements
            // that block event posting.
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Security"),
                .linkedFramework("Network"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        .testTarget(
            name: "SameDeskTests",
            dependencies: ["SameDesk"],
            path: "Tests/SameDeskTests"
        )
    ]
)
