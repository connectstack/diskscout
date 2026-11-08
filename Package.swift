// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DiskScout",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DiskScout", targets: ["DiskScout"])
    ],
    targets: [
        .executableTarget(
            name: "DiskScout",
            path: "Sources/DiskScout"
        ),
        .testTarget(
            name: "DiskScoutTests",
            dependencies: ["DiskScout"],
            path: "Tests/DiskScoutTests"
        )
    ]
)
