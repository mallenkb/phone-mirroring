// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PhoneRelay",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        // The product (and thus the built executable) is named "Android
        // Mirroring" so debug runs show the real app name in the Dock; the
        // packaging scripts rename it back to PhoneRelay inside the
        // bundle to keep CFBundleExecutable (and the app identity) unchanged.
        .executable(
            name: "PhoneRelayBinary",
            targets: ["PhoneRelayApp"]
        ),
        // Library product so the Xcode wrapper app (App/) can link the same
        // code for Archive/App Store distribution.
        .library(
            name: "PhoneRelayKit",
            targets: ["PhoneRelay"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.3"),
        .package(url: "https://github.com/PostHog/posthog-ios.git", from: "3.59.3")
    ],
    targets: [
        .executableTarget(
            name: "PhoneRelayApp",
            dependencies: ["PhoneRelay"],
            path: "Sources/PhoneRelayApp",
            linkerSettings: [
                // Embed Info.plist into the executable so debug runs (Xcode /
                // `swift run`) have a bundle identity and local-network usage
                // declarations; without these macOS denies Local Network
                // access and Wi-Fi adb fails with "No route to host".
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/PhoneRelay/Info.plist"
                ])
            ]
        ),
        .target(
            name: "ObjCSupport",
            path: "Sources/ObjCSupport"
        ),
        .target(
            name: "PhoneRelay",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "PostHog", package: "posthog-ios"),
                "ObjCSupport"
            ],
            path: "Sources/PhoneRelay",
            exclude: ["Info.plist"],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "PhoneRelayTests",
            dependencies: ["PhoneRelay"],
            path: "Tests/PhoneRelayTests"
        )
    ]
)
