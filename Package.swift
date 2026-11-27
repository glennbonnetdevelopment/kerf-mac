// swift-tools-version:5.9
import Foundation
import PackageDescription

/// The camera permission text, embedded in the executable (a plain SwiftPM binary has no Info.plist).
let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Resources/Info-SwiftPM.plist").path

let package = Package(
    name: "KerfKutter",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "KerfKutter", targets: ["KerfKutter"]),
        .library(name: "KerfCore", targets: ["KerfCore"]),
    ],
    targets: [
        .target(name: "KerfCore"),
        .executableTarget(name: "KerfKutter", dependencies: ["KerfCore"], path: "Sources/Kerf",
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                                                         "-Xlinker", "__info_plist", "-Xlinker", infoPlist])]),
        .testTarget(name: "KerfCoreTests", dependencies: ["KerfCore"]),
    ]
)
