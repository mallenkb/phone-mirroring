// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AndroidMirrorMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "AndroidMirrorMac",
            targets: ["AndroidMirrorMac"]
        )
    ],
    targets: [
        .executableTarget(
            name: "AndroidMirrorMac",
            path: "Sources/AndroidMirrorMac",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "AndroidMirrorMacTests",
            dependencies: ["AndroidMirrorMac"],
            path: "Tests/AndroidMirrorMacTests"
        )
    ]
)
