// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "HERMES",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "tool", targets: ["HermesTool"]),
        .library(name: "HermesNetworking", targets: ["HermesNetworking"])
    ],
    targets: [
        .target(
            name: "HermesNetworking",
            path: "Sources",
            sources: [
                "DownloaderHTTPCompatibility.swift",
                "Utilities/DownloaderNetworkPolicy.swift"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
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
        ),
        .testTarget(
            name: "HermesNetworkingTests",
            dependencies: ["HermesNetworking"],
            path: "Tests/HermesNetworkingTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
