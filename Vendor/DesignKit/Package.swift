// swift-tools-version:5.9
import PackageDescription

// DesignKit: a native SwiftUI design system for Mac apps, ported from Intent (see NOTICE).
let package = Package(
    name: "DesignKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "DesignKit", targets: ["DesignKit"])],
    targets: [.target(name: "DesignKit", path: "Sources/DesignKit")]
)
