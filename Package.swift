// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Halation",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Halation", path: "Sources/Halation")
    ]
)
