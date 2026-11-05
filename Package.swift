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
        // The only pipeline module the app may import. The share extension must NOT import it (decision 0003).
        .library(name: "StillMotionsPipeline", targets: ["StillMotionsPipeline"]),
        // The hand-off between the share extension and the app: Foundation only, no pipeline. The extension
        // links this and nothing else of ours.
        .library(name: "DropBox", targets: ["DropBox"]),
        // Quality harness. macOS only in practice; see docs/PRD.md R-22.
        .executable(name: "stillmotions-harness", targets: ["HarnessCLI"]),
    ],
    targets: [
        // MARK: - Core vocabulary

        // Value types and protocols shared by every stage. No platform dependencies
        // beyond Foundation/CoreVideo/simd.
        .target(name: "PipelineCore"),

        // MARK: - Share hand-off

        // The share extension's drop box and the manifest it shares with the app (issue #36). Depends on
        // nothing, so the extension never links the pipeline.
        .target(name: "DropBox"),

        // MARK: - Pipeline stages

        // File-based import (HEIC + MOV pair) and the streaming frame decoder. Not in the
        // original ARCHITECTURE §1 module table — added in #8 because AVFoundation (needed
        // to decode) is beyond PipelineCore's stated Foundation/CoreVideo/simd-only scope.
        .target(name: "Import", dependencies: ["PipelineCore"]),
        .target(name: "MotionEstimation", dependencies: ["PipelineCore"]),
        .target(name: "CameraPath", dependencies: ["PipelineCore"]),
        .target(name: "LoopSelection", dependencies: ["PipelineCore"]),
        .target(name: "Rendering", dependencies: ["PipelineCore"]),

        // Encoding depends on CGifski, a binary target over Vendor/Gifski.xcframework. That is
        // a gitignored build artifact: SwiftPM cannot load this manifest until
        // ./scripts/build-gifski.sh has produced it (CI builds and caches it; see
        // .github/workflows/verify.yml). See docs/decisions/0004-gifski-integration.md.
        .target(
            name: "Encoding",
            dependencies: [
                "PipelineCore",
                "CGifski",
            ]
        ),

        // MARK: - gifski
        .binaryTarget(name: "CGifski", path: "Vendor/Gifski.xcframework"),

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
                "DropBox",
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
            // HarnessCLI too: SwiftPM lets tests `@testable import` an executable, which is how the
            // harness's own logic (clip discovery, failure handling) is tested.
            dependencies: ["StillMotionsPipeline", "HarnessCLI"],
            path: "tests/PipelineTests"
        ),
    ]
)
