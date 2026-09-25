// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LocalizeMe",
    // Only the tests carry localized resources; the library has none.
    defaultLocalization: "en",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .watchOS(.v8),
    ],
    products: [
        .library(name: "LocalizeMe", targets: ["LocalizeMe"]),
        // Typed accessors (`L10n.homeTitle`) generated from the app's string
        // tables on every build. See "Typed accessors" in the README.
        .plugin(name: "LocalizeMeStrings", targets: ["LocalizeMeStrings"]),
    ],
    targets: [
        .target(
            name: "LocalizeMe",
            path: "Sources/LocalizeMe"
        ),
        .target(
            name: "LocalizeMeStringsCore",
            path: "Sources/LocalizeMeStringsCore"
        ),
        .executableTarget(
            name: "LocalizeMeStringsGenerator",
            dependencies: ["LocalizeMeStringsCore"],
            path: "Sources/LocalizeMeStringsGenerator"
        ),
        .plugin(
            name: "LocalizeMeStrings",
            capability: .buildTool(),
            dependencies: ["LocalizeMeStringsGenerator"],
            path: "Plugins/LocalizeMeStrings"
        ),
        .testTarget(
            name: "LocalizeMeTests",
            dependencies: ["LocalizeMe"],
            path: "Tests/LocalizeMeTests",
            // The string catalog is copied, not compiled: compiling one needs
            // Xcode, and the tests only need the plugin to read it.
            resources: [.process("Resources"), .copy("Fixtures/Onboarding.xcstrings")],
            plugins: [.plugin(name: "LocalizeMeStrings")]
        ),
        .testTarget(
            name: "LocalizeMeStringsCoreTests",
            dependencies: ["LocalizeMeStringsCore"],
            path: "Tests/LocalizeMeStringsCoreTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
