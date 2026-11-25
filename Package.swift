// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "KerfKutter",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "KerfKutter", targets: ["KerfKutter"]),
        .library(name: "KerfCore", targets: ["KerfCore"]),
    ],
    targets: [
        .target(name: "KerfCore"),
        .executableTarget(name: "KerfKutter", dependencies: ["KerfCore"], path: "Sources/Kerf"),
        .testTarget(name: "KerfCoreTests", dependencies: ["KerfCore"]),
    ]
)
