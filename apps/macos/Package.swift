// swift-tools-version:5.9
// JARVIS OS native macOS app. Minimum macOS 14 (Observation framework, MenuBarExtra, NavigationSplitView).
// Build:  swift build -c release      Test:  swift test      Run (dev):  swift run JarvisOS
import PackageDescription

let package = Package(
    name: "JarvisOS",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "JarvisCore", targets: ["JarvisCore"]),
        .executable(name: "JarvisOS", targets: ["JarvisOS"]),
    ],
    targets: [
        .target(name: "JarvisCore"),
        .executableTarget(name: "JarvisOS", dependencies: ["JarvisCore"]),
        .testTarget(name: "JarvisCoreTests", dependencies: ["JarvisCore"], resources: [.copy("Fixtures")]),
    ]
)
