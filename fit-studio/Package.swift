// swift-tools-version:5.9
import PackageDescription

var targets: [Target] = [
    // Platform-independent logic: FIT decoding, channels and statistics, percentage adjustment,
    // comparison and CSV export.
    .target(name: "FITStudioCore"),
    .testTarget(name: "FITStudioCoreTests", dependencies: ["FITStudioCore"], resources: [.copy("Fixtures")]),
    // Command-line tool for the same features (info, adjust, compare, csv).
    .executableTarget(name: "fitstudio-cli", dependencies: ["FITStudioCore"]),
]
var products: [Product] = [
    .library(name: "FITStudioCore", targets: ["FITStudioCore"]),
    .executable(name: "fitstudio", targets: ["fitstudio-cli"]),
]

#if os(macOS)
// The app itself (SwiftUI + Swift Charts) only builds on macOS.
targets.append(.executableTarget(name: "FITStudio", dependencies: ["FITStudioCore"]))
products.append(.executable(name: "FITStudio", targets: ["FITStudio"]))
#endif

let package = Package(
    name: "FITStudio",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
