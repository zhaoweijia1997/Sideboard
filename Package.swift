// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Sideboard",
    platforms: [.macOS(.v14)],
    targets: [
        // Localizations live in Resources/Localization and are copied into the
        // app bundle by build.sh, so SwiftUI finds them in Bundle.main.
        .executableTarget(
            name: "Sideboard", path: "Sources/Sideboard",
            // `/…/` regex literals, used to read adb output.
            swiftSettings: [.enableUpcomingFeature("BareSlashRegexLiterals")],
            // SwiftUI's VideoPlayer finds AVKit's player view by name at run time; SwiftPM doesn't
            // link AVKit on its own, and without it the recording preview crashes.
            linkerSettings: [.linkedFramework("AVKit")]),
    ]
)
