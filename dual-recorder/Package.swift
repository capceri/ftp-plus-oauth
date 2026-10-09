// swift-tools-version:5.9
import PackageDescription

var targets: [Target] = [
    // Platform-independent logic: Bluetooth payload parsing, per-second sampling,
    // ride statistics, crash-recovery journal and the FIT encoder.
    .target(name: "DualRecorderCore"),
    .testTarget(name: "DualRecorderCoreTests", dependencies: ["DualRecorderCore"]),
]
var products: [Product] = [
    .library(name: "DualRecorderCore", targets: ["DualRecorderCore"]),
]

#if os(macOS)
// The app itself (SwiftUI + CoreBluetooth) only builds on macOS.
targets.append(.executableTarget(name: "DualRecorder", dependencies: ["DualRecorderCore"]))
products.append(.executable(name: "DualRecorder", targets: ["DualRecorder"]))
#endif

let package = Package(
    name: "DualRecorder",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
