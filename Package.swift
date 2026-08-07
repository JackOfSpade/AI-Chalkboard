// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIChalkboard",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AIChalkboard", targets: ["AIChalkboard"])
    ],
    targets: [
        .target(
            name: "AIChalkboardCore",
            path: "Sources"
        ),
        .executableTarget(
            name: "AIChalkboard",
            dependencies: ["AIChalkboardCore"],
            path: "Launcher"
        ),
        .testTarget(
            name: "AIChalkboardCoreTests",
            dependencies: ["AIChalkboardCore"],
            path: "tests/AIChalkboardCoreTests"
        )
    ]
)
