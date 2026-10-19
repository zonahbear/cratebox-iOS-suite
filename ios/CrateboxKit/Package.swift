// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CrateboxKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "CrateboxKit", targets: ["CrateboxKit"])],
    targets: [
        .target(name: "CrateboxKit"),
        .testTarget(name: "CrateboxKitTests", dependencies: ["CrateboxKit"], resources: [.copy("Fixtures")]),
    ]
)
