// swift-tools-version: 6.0
import PackageDescription

// A dependency-free test harness for the app's Foundation-only core. Runs on macOS or Linux.
let package = Package(
    name: "MotionCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "MotionCore", targets: ["MotionCore"])],
    targets: [
        .target(name: "MotionCore", path: "Motion/Core"),
        .testTarget(name: "MotionCoreTests", dependencies: ["MotionCore"], path: "MotionTests",
                    exclude: ["PersistenceTests.swift", "CoordinatorTests.swift", "SyncPersistenceTests.swift", "MotionAuthenticationTests.swift", "HelioSleepTests.swift", "SleepHealthAccessTests.swift"])
    ]
)
