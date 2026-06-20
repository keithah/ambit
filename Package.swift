// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ambit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "AmbitCore", targets: ["AmbitCore"]),
        .executable(name: "AmbitMenuBar", targets: ["AmbitMenuBar"]),
        .executable(name: "ambit-check", targets: ["AmbitCheck"])
    ],
    targets: [
        .target(name: "AmbitCore"),
        .executableTarget(
            name: "AmbitMenuBar",
            dependencies: ["AmbitCore"],
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(name: "AmbitCheck", dependencies: ["AmbitCore"]),
        .testTarget(name: "AmbitCoreTests", dependencies: ["AmbitCore"])
    ]
)
