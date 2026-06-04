// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacTranslator",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MacTranslator",
            path: "Sources/MacTranslator"
        )
    ],
    swiftLanguageModes: [.v5]
)
