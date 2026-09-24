// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LocalizeMe",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .watchOS(.v8),
    ],
    products: [
        .library(name: "LocalizeMe", targets: ["LocalizeMe"]),
    ],
    targets: [
        .target(
            name: "LocalizeMe",
            path: "Sources/LocalizeMe"
        ),
        .testTarget(
            name: "LocalizeMeTests",
            dependencies: ["LocalizeMe"],
            path: "Tests/LocalizeMeTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
