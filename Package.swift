// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetingScribe",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "MeetingScribe",
            path: "Sources/MeetingScribe",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
