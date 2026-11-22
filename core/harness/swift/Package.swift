// swift-tools-version: 6.0
import PackageDescription

// Loads the packaged XCFramework of the shared core (ADR 0025) and runs the
// conformance vectors through it. core.yml writes build/ and the generated
// Swift bindings into Sources/SeptenaSharedCore before it runs this package.
let package = Package(
    name: "SeptenaCoreHarness",
    platforms: [.iOS(.v17), .macOS(.v14)],
    targets: [
        .binaryTarget(name: "SeptenaSharedCoreFFI", path: "build/SeptenaSharedCoreFFI.xcframework"),
        .target(
            name: "SeptenaSharedCore",
            dependencies: ["SeptenaSharedCoreFFI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SeptenaCoreHarnessTests",
            dependencies: ["SeptenaSharedCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
