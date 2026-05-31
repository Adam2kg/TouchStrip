// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TouchStrip",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "TouchStrip",
            path: "Sources/TouchStrip",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("IOKit"),
            ]
        )
    ]
)
