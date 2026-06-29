// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "HERMES",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "tool", targets: ["HermesTool"])
    ],
    targets: [
        .executableTarget(
            name: "HermesTool",
            path: "Sources",
            sources: ["tool.swift"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("ImageIO"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        )
    ]
)
