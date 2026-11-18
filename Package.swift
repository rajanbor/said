// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Said",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Said", path: "Sources/Said")
    ]
)
