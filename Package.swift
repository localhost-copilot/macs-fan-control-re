// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacsFanControlSwift",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "FanControl", targets: ["FanControl"]),
        .executable(name: "FanHelper", targets: ["FanHelper"])
    ],
    targets: [
        .target(name: "FanCore", resources: [.copy("Resources")], linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("Security")]),
        .executableTarget(name: "FanControl", dependencies: ["FanCore"]),
        .executableTarget(name: "FanHelper", dependencies: ["FanCore"]),
        .testTarget(name: "FanCoreTests", dependencies: ["FanCore"]),
        .testTarget(name: "FanControlTests", dependencies: ["FanControl", "FanCore"])
    ]
)
