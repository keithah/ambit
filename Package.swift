// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GLiNetTravel",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "GLiNetCore", targets: ["GLiNetCore"]),
        .executable(name: "GLiNetMenuBar", targets: ["GLiNetMenuBar"]),
        .executable(name: "glinet-router-check", targets: ["RouterCheck"])
    ],
    targets: [
        .target(name: "GLiNetCore"),
        .executableTarget(
            name: "GLiNetMenuBar",
            dependencies: ["GLiNetCore"],
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(name: "RouterCheck", dependencies: ["GLiNetCore"]),
        .testTarget(name: "GLiNetCoreTests", dependencies: ["GLiNetCore"])
    ]
)
