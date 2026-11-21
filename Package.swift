// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AmbitKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "AmbitKit", targets: ["AmbitKit"])],
    targets: [
        .target(name: "AmbitKit"),
        .executableTarget(name: "ambit-probe", dependencies: ["AmbitKit"]),
        .testTarget(name: "AmbitKitTests", dependencies: ["AmbitKit"]),
    ]
)
