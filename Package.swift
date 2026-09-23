// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PhotoImport",
    platforms: [.macOS(.v15)],
    targets: [
        // Everything testable without an iPhone: library layout, dedupe, import/delete gating, similar-photo logic.
        .target(name: "PhotoImportCore"),
        // The SwiftUI app plus the ImageCaptureCore glue that talks to the phone.
        .executableTarget(name: "PhotoImport", dependencies: ["PhotoImportCore"]),
        .testTarget(name: "PhotoImportCoreTests", dependencies: ["PhotoImportCore"]),
    ],
    // Swift 5 mode: ImageCaptureCore and Vision types predate Sendable annotations.
    swiftLanguageModes: [.v5]
)
