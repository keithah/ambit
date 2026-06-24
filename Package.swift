// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ambit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "AmbitCore", targets: ["AmbitCore"]),
        .library(name: "AmbitUI", targets: ["AmbitUI"]),
        .executable(name: "Ambit", targets: ["AmbitMenuBar"]),
        .executable(name: "ambit-check", targets: ["AmbitCheck"])
    ],
    targets: [
        .target(name: "AmbitCore"),
        .target(name: "AmbitUI", dependencies: ["AmbitCore"]),
        .executableTarget(
            name: "AmbitMenuBar",
            dependencies: ["AmbitCore", "AmbitUI"],
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(name: "AmbitCheck", dependencies: ["AmbitCore"]),
        .testTarget(name: "AmbitCoreTests", dependencies: ["AmbitCore"]),
        .testTarget(name: "AmbitUITests", dependencies: ["AmbitUI", "AmbitCore"])
    ]
)
