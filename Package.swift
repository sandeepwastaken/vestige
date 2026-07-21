// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Vestige",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Vestige", targets: ["Vestige"])
    ],
    targets: [
        .executableTarget(
            name: "Vestige",
            path: "Sources/Vestige",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("Carbon")
            ]
        ),
        .testTarget(
            name: "VestigeTests",
            dependencies: ["Vestige"]
        )
    ]
)
