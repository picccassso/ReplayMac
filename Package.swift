// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ReplayCap",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "ReplayCap", targets: ["ReplayCap"]),
        // Library product consumed by the Xcode wrapper project
        // (AppStore/ReplayCap.xcodeproj), whose app target compiles
        // Sources/App itself and links these modules.
        .library(
            name: "ReplayCapKit",
            targets: ["Branding", "Capture", "Encode", "RingBuffer", "Save", "Audio", "UI", "Hotkeys", "Feedback"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.2.0"),
        .package(url: "https://github.com/sindresorhus/Defaults", from: "9.0.0")
    ],
    targets: [
        .executableTarget(
            name: "ReplayCap",
            dependencies: [
                "Branding", "Capture", "Encode", "RingBuffer", "Save", "Audio", "UI", "Hotkeys", "Feedback",
                .product(name: "Defaults", package: "Defaults")
            ],
            path: "Sources/App",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .target(
            name: "Branding",
            path: "Sources/Branding"
        ),
        .target(
            name: "Capture",
            dependencies: ["Branding"],
            path: "Sources/Capture",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreImage")
            ]
        ),
        .target(
            name: "Encode",
            path: "Sources/Encode",
            linkerSettings: [
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia")
            ]
        ),
        .target(
            name: "RingBuffer",
            dependencies: [.product(name: "DequeModule", package: "swift-collections")],
            path: "Sources/RingBuffer",
            linkerSettings: [
                .linkedFramework("CoreMedia")
            ]
        ),
        .target(
            name: "Save",
            dependencies: ["Branding", "RingBuffer"],
            path: "Sources/Save",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia")
            ]
        ),
        .target(
            name: "Audio",
            path: "Sources/Audio",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("ScreenCaptureKit")
            ]
        ),
        .target(
            name: "UI",
            dependencies: [
                "Branding",
                "Audio",
                "Capture",
                "Save",
                "Hotkeys",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "Defaults", package: "Defaults")
            ],
            path: "Sources/UI"
        ),
        .target(
            name: "Hotkeys",
            dependencies: [.product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")],
            path: "Sources/Hotkeys"
        ),
        .target(
            name: "Feedback",
            dependencies: ["Branding"],
            path: "Sources/Feedback",
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AppKit"),
                .linkedFramework("UserNotifications")
            ]
        ),
        .testTarget(name: "RingBufferTests", dependencies: ["RingBuffer"], path: "Tests/RingBufferTests"),
        .testTarget(name: "EncoderTests", dependencies: ["Encode"], path: "Tests/EncoderTests"),
        .testTarget(name: "SavePipelineTests", dependencies: ["Save", "RingBuffer"], path: "Tests/SavePipelineTests"),
        .testTarget(name: "CaptureTests", dependencies: ["Capture"], path: "Tests/CaptureTests"),
        .testTarget(name: "AudioTests", dependencies: ["Audio"], path: "Tests/AudioTests"),
        .testTarget(name: "UITests", dependencies: ["UI"], path: "Tests/UITests")
    ]
)
