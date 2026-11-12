// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Typemore",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Typemore", targets: ["Typemore"])
    ],
    targets: [
        .executableTarget(name: "Typemore"),
        .testTarget(name: "TypemoreTests", dependencies: ["Typemore"])
    ]
)
