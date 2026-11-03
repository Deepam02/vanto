// swift-tools-version: 6.0
import PackageDescription

// With only the Command Line Tools installed (no Xcode), SwiftPM doesn't add the search
// path for the Swift Testing framework. Harmless when Xcode is present.
let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let cltLibs = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

let package = Package(
    name: "VoiceCommand",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VoiceCommand", targets: ["VoiceCommand"]),
        .executable(name: "router-eval", targets: ["router-eval"]),
        .executable(name: "log-report", targets: ["log-report"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.2"),
        // Vendored 3.1.0 with the SwiftUI macros patched out (see Vendor/KeyboardShortcuts/PATCHES.md).
        .package(path: "Vendor/KeyboardShortcuts"),
    ],
    targets: [
        // Foundation-only logic: router, prompt, tool schemas, safety, transcript, logging.
        .target(
            name: "VoiceCommandCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "VoiceCommand",
            dependencies: [
                "VoiceCommandCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "router-eval",
            dependencies: ["VoiceCommandCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "log-report",
            dependencies: ["VoiceCommandCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "VoiceCommandCoreTests",
            dependencies: ["VoiceCommandCore"],
            swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-F", cltFrameworks])],
            linkerSettings: [.unsafeFlags(["-F", cltFrameworks, "-Xlinker", "-rpath", "-Xlinker", cltFrameworks, "-Xlinker", "-rpath", "-Xlinker", cltLibs])]
        ),
    ]
)
