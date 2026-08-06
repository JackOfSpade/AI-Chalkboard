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
        .executableTarget(
            name: "AIChalkboard",
            path: "Sources"
        )
    ]
)
