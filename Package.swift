// swift-tools-version: 6.0
// StillMotionsPipeline — the processing pipeline, with no UI or PhotoKit dependency.
// Builds and tests on macOS so stabilization quality can be measured headlessly.
// See docs/ARCHITECTURE.md §1 and PRD R-24.

import PackageDescription

let package = Package(
    name: "StillMotionsPipeline",
    // Version strings rather than enum cases (.v27 etc.) so the manifest does not depend
    // on which SupportedPlatform cases a given toolchain happens to define.
    platforms: [
        .iOS("27.0"),
        .macOS("15.0"),
    ],
    products: [
        // The only module the app and extension may import.
        .library(name: "StillMotionsPipeline", targets: ["StillMotionsPipeline"]),
        // Quality harness. macOS only in practice; see docs/PRD.md R-22.
        .executable(name: "stillmotions-harness", targets: ["HarnessCLI"]),
    ],
    targets: [
        // MARK: - Core vocabulary

        // Value types and protocols shared by every stage. No platform dependencies
        // beyond Foundation/CoreVideo/simd.
        .target(name: "PipelineCore"),

        // MARK: - Pipeline stages

        // File-based import (HEIC + MOV pair) and the streaming frame decoder. Not in the
        // original ARCHITECTURE §1 module table — added in #8 because AVFoundation (needed
        // to decode) is beyond PipelineCore's stated Foundation/CoreVideo/simd-only scope.
        .target(name: "Import", dependencies: ["PipelineCore"]),
        .target(name: "MotionEstimation", dependencies: ["PipelineCore"]),
        .target(name: "CameraPath", dependencies: ["PipelineCore"]),
        .target(name: "LoopSelection", dependencies: ["PipelineCore"]),
        .target(name: "Rendering", dependencies: ["PipelineCore"]),

        // Encoding depends on CGifski once the xcframework exists. Both the binary target
        // and this dependency are commented out deliberately: SwiftPM fails to load a
        // manifest whose binaryTarget path is missing, and Vendor/Gifski.xcframework is a
        // gitignored build artifact. Uncomment both in the gifski integration issue, after
        // scripts/build-gifski.sh has been run. See docs/decisions/0004-gifski-integration.md.
        .target(
            name: "Encoding",
            dependencies: [
                "PipelineCore",
                // "CGifski",
            ]
        ),

        // MARK: - gifski
        // .binaryTarget(name: "CGifski", path: "Vendor/Gifski.xcframework"),

        // MARK: - Public façade

        // The single public entry point. The app, the extension-free drop box flow, and the
        // harness all call through here, so the harness measures the shipping pipeline
        // rather than a parallel implementation.
        .target(
            name: "StillMotionsPipeline",
            dependencies: [
                "PipelineCore",
                "Import",
                "MotionEstimation",
                "CameraPath",
                "LoopSelection",
                "Rendering",
                "Encoding",
            ]
        ),

        // MARK: - Harness

        .executableTarget(
            name: "HarnessCLI",
            dependencies: ["StillMotionsPipeline"]
        ),

        // MARK: - Tests
        // Path is explicit and lowercase. macOS APFS is case-insensitive, so a conventional
        // `Tests/` directory would be the same directory as the brief-mandated
        // `tests/fixtures/`. Never create `Tests/`. See docs/ARCHITECTURE.md §8.
        .testTarget(
            name: "PipelineTests",
            dependencies: ["StillMotionsPipeline"],
            path: "tests/PipelineTests"
        ),
    ]
)
