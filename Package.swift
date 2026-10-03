// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CleanSSD",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "CleanSSD",
            path: "Sources/CleanSSD"
        )
    ]
)
