// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OKYC",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "OKYC", targets: ["OKYC"]),
    ],
    targets: [
        .target(
            name: "OKYC",
            path: "Sources/OKYC",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
    ]
)
