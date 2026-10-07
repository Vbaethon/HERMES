// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "HERMES",
    platforms: [
        .macOS("27.0")
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
                "Utilities/SubprocessRunner.swift",
                "Utilities/DouyinSourceResolver.swift",
                "Utilities/DewuDownloadRecoveryPolicy.swift",
                "Utilities/DewuPlaybackLogVideoExtractor.swift",
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
        .target(
            name: "HermesThumbnailUI",
            path: "Sources",
            sources: [
                "UIModels.swift", "Utilities/FileSystemUtilities.swift",
                "Views/CollectionViews/ThumbnailGridController.swift",
                "Views/CollectionViews/ThumbnailGridArrangementController.swift",
                "Views/CollectionViews/ThumbnailGridZoomController.swift",
                "Views/CollectionViews/ThumbnailZoomGeometry.swift",
                "Views/CollectionViews/ThumbnailZoomOverlay.swift",
                "Utilities/NativeMediaResources.swift",
                "Views/Thumbnail/ThumbnailService.swift",
                "Views/Thumbnail/ThumbnailItemViews.swift",
                "Views/Thumbnail/ThumbnailCompositionEffect.swift",
                "Views/Thumbnail/SystemThumbnailProvider.swift",
                "Views/Other/MediaLocationCard.swift"
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "HermesLayoutTests",
            dependencies: ["HermesThumbnailUI"],
            path: "Tests/HermesLayoutTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
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
