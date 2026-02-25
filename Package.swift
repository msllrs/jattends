// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Jattends",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Jattends",
            path: "Sources/Jattends"
        )
    ]
)
