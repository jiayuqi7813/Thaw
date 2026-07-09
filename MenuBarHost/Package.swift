// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "MenuBarHost",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MenuBarHost", targets: ["MenuBarHost"]),
    ],
    dependencies: [
        .package(path: "../MenuBarModel"),
    ],
    targets: [
        .target(
            name: "MenuBarHost",
            dependencies: [
                .product(name: "MenuBarModel", package: "MenuBarModel"),
            ]
        ),
    ]
)
