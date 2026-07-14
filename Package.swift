// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacTranslator",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "MacTranslatorCore",
            path: "Sources/MacTranslatorCore"
        ),
        .executableTarget(
            name: "MacTranslator",
            dependencies: ["MacTranslatorCore"],
            path: "Sources/MacTranslator"
        ),
        .executableTarget(
            name: "MacTranslatorTests",
            dependencies: ["MacTranslatorCore"],
            path: "Tests/MacTranslatorTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
