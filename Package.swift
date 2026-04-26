// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ReplayMac",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "ReplayMac", targets: ["ReplayMac"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.2.0"),
        .package(url: "https://github.com/sindresorhus/Defaults", from: "9.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "ReplayMac",
            dependencies: ["Capture", "Encode", "RingBuffer", "Save", "Audio", "UI", "Hotkeys", "Feedback", "Update"],
            path: "Sources/App",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .target(
            name: "Capture",
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
            dependencies: ["RingBuffer"],
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
                .linkedFramework("CoreMedia")
            ]
        ),
        .target(
            name: "UI",
            dependencies: [
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
            path: "Sources/Feedback",
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AppKit"),
                .linkedFramework("UserNotifications")
            ]
        ),
        .target(
            name: "Update",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Update"
        ),
        .testTarget(name: "RingBufferTests", dependencies: ["RingBuffer"], path: "Tests/RingBufferTests"),
        .testTarget(name: "EncoderTests", dependencies: ["Encode"], path: "Tests/EncoderTests"),
        .testTarget(name: "SavePipelineTests", dependencies: ["Save", "RingBuffer"], path: "Tests/SavePipelineTests"),
        .testTarget(name: "CaptureTests", dependencies: ["Capture"], path: "Tests/CaptureTests")
    ]
)
