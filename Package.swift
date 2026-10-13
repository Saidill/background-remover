// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BackgroundRemover",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "BackgroundRemover",
            path: "Sources/BackgroundRemover",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
