// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Said",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.1.1"),
    ],
    targets: [
        // llama.cpp, prebuilt by the llama.cpp project (Metal shaders embedded), pinned by checksum.
        // Runs the local summary model. Prebuilt, so building Said still needs only the Command Line Tools.
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b12024/llama-b12024-xcframework.zip",
            checksum: "b7005ad25dab07d273794afc7ac24d55aeac1b52376301907c5fb4762e42545d"
        ),
        .executableTarget(
            name: "Said",
            dependencies: [.product(name: "WhisperKit", package: "WhisperKit"), "llama"],
            path: "Sources/Said",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
