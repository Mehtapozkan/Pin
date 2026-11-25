// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Pin",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "PinCore", targets: ["PinCore"]), .library(name: "PinMemory", targets: ["PinMemory"])],
    dependencies: [.package(path: "../iBrain")],
    targets: [
        .target(name: "PinCore"),
        .target(name: "PinMemory", dependencies: ["PinCore", .product(name: "IBrain", package: "iBrain"),
            .product(name: "IBrainSemantics", package: "iBrain"), .product(name: "IBrainRetrieval", package: "iBrain"),
            .product(name: "IBrainVision", package: "iBrain")]),
        .testTarget(name: "PinCoreTests", dependencies: ["PinCore"])
    ])
