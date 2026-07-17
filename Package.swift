// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Damso",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Damso", targets: ["Damso"])
    ],
    targets: [
        .executableTarget(
            name: "Damso",
            resources: [.process("Resources")]
        ),
        .testTarget(name: "DamsoTests", dependencies: ["Damso"])
    ]
)
