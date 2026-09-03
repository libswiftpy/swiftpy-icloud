// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "swiftpy-icloud",
    platforms: [.iOS(.v26), .macOS(.v26), .visionOS(.v26)],
    products: [
        .library(
            name: "SwiftPyICloud",
            targets: ["SwiftPyICloud"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/felfoldy/SwiftPy", from: "0.28.0"),
    ],
    targets: [
        .target(
            name: "SwiftPyICloud",
            dependencies: ["SwiftPy"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
        .testTarget(
            name: "SwiftPyICloudTests",
            dependencies: ["SwiftPyICloud"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
    ]
)
