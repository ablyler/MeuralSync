// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeuralSync",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "MeuralSyncCore",
            targets: ["MeuralSyncCore"]
        ),
        .executable(
            name: "MeuralSyncApp",
            targets: ["MeuralSyncApp"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "MeuralSyncCore",
            resources: [
                .copy("Resources/parks"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Photos"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("Security"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("ImageIO"),
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "MeuralSyncApp",
            dependencies: [
                "MeuralSyncCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            linkerSettings: [
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Photos"),
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(
            name: "MeuralSyncCoreTests",
            dependencies: ["MeuralSyncCore"]
        ),
    ]
)
