// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DawriCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "DawriCore", targets: ["DawriCore"]),
    ],
    targets: [
        .target(
            name: "DawriCore",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "DawriCoreTests",
            dependencies: ["DawriCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
