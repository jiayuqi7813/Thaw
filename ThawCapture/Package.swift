// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "ThawCapture",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ThawCapture", targets: ["ThawCapture"]),
    ],
    dependencies: [
        .package(path: "../MenuBarModel"),
    ],
    targets: [
        .target(
            name: "ThawCapture",
            dependencies: [
                .product(name: "MenuBarModel", package: "MenuBarModel"),
            ]
        ),
        .testTarget(
            name: "ThawCaptureTests",
            dependencies: ["ThawCapture"]
        ),
    ]
)
