// swift-tools-version: 6.0
import PackageDescription

// A dependency-free test harness for the app's Foundation-only core. Runs on macOS or Linux.
let package = Package(
    name: "VitalsCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "VitalsCore", targets: ["VitalsCore"])],
    targets: [
        .target(name: "VitalsCore", path: "Vitals/Core"),
        .testTarget(name: "VitalsCoreTests", dependencies: ["VitalsCore"], path: "VitalsTests",
                    exclude: ["PersistenceTests.swift", "CoordinatorTests.swift"])
    ]
)
