// swift-tools-version:6.0
// Capture: a menu bar app for screenshots, scrolling captures, screen recordings and voice thoughts.
// build.sh wraps the executable into Capture.app. CaptureCore holds the logic that is tested without a screen.
import PackageDescription

let package = Package(
    name: "Capture",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Capture", targets: ["CaptureApp"])],
    // DesignKit: a native SwiftUI port of the Intent design system (Apache-2.0), vendored in Vendor/DesignKit. Light and dark come from it.
    dependencies: [.package(path: "Vendor/DesignKit")],
    targets: [
        .target(name: "CaptureCore", path: "Sources/CaptureCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "CaptureApp", dependencies: ["CaptureCore", .product(name: "DesignKit", package: "DesignKit")], path: "Sources/Capture", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "CaptureCoreTests", dependencies: ["CaptureCore"], path: "Tests/CaptureCoreTests", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
