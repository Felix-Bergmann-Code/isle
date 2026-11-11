// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Isle",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Isle",
            path: "Sources/Isle",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("IOBluetooth"),
                .linkedFramework("EventKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreMediaIO"),
                .linkedFramework("IOKit"),
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("AVFoundation"),
            ]
        ),
    ]
)
