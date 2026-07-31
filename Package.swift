// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MenuBarLyrics",
    platforms: [.macOS("15.4")],
    targets: [
        .executableTarget(
            name: "MenuBarLyrics",
            path: "MenuBarLyrics",
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "MenuBarLyricsTests",
            dependencies: ["MenuBarLyrics"],
            path: "MenuBarLyricsTests"
        ),
    ]
)
