// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "xiv-kr-launcher",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "XIVKRLauncher", targets: ["XIVKRLauncher"]),
    ],
    targets: [
        .executableTarget(
            name: "XIVKRLauncher",
            path: "Sources/XIVKRLauncher"
        ),
        .testTarget(
            name: "XIVKRLauncherTests",
            dependencies: ["XIVKRLauncher"],
            path: "Tests/XIVKRLauncherTests"
        ),
    ]
)
