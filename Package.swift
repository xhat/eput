// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DaXiangShuo",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DaXiangShuo",
            path: "Sources/DaXiangShuo",
            swiftSettings: [
                .unsafeFlags(["-Osize"], .when(configuration: .release)),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .unsafeFlags(["-Xlinker", "-dead_strip"], .when(configuration: .release)),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
