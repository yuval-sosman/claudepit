// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Claudepit",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Swift syntax highlighter for diff/code rendering (UI only).
        .package(url: "https://github.com/JohnSundell/Splash", from: "0.16.0"),
        // highlight.js (via WebKit/JavaScriptCore) for ~190 non-Swift languages (UI only).
        .package(url: "https://github.com/raspu/Highlightr", from: "2.2.0"),
    ],
    targets: [
        // All testable logic (models + config scanning/merging/writing) lives here
        // so both the app and the check-runner can link it. (An executable target's
        // @main module can't be linked into another target.)
        .target(
            name: "ClaudepitCore",
            path: "Sources/ClaudepitCore"
        ),
        .executableTarget(
            name: "ClaudepitApp",
            dependencies: ["ClaudepitCore", .product(name: "Splash", package: "Splash"), .product(name: "Highlightr", package: "Highlightr")],
            path: "Sources/ClaudepitApp",
            resources: [
                .copy("Resources/d3.min.js"),
                .copy("Resources/hooks-lifecycle.png"),
            ]
        ),
        // Assert-based checks (no XCTest — this machine has only the CLI toolchain,
        // and XCTest/Testing ship with full Xcode). Run: `swift run ClaudepitTests`.
        .executableTarget(
            name: "ClaudepitTests",
            dependencies: ["ClaudepitCore"],
            path: "Tests/ClaudepitTests"
        ),
    ]
)
