// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LocalGrammar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "LocalGrammar", path: "Sources/LocalGrammar")
    ]
)
