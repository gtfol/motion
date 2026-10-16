// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "HelioProtocol", platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ZeppKit", targets: ["ZeppKit"]),
               .library(name: "ZeppKitTesting", targets: ["ZeppKitTesting"])],
    targets: [.target(name: "ZeppKit"),
              .target(name: "ZeppKitTesting", dependencies: ["ZeppKit"]),
              .testTarget(name: "ZeppKitTests", dependencies: ["ZeppKit", "ZeppKitTesting"])])
