// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Veloce",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Veloce", targets: ["Veloce"]), .library(name: "VeloceCore", targets: ["VeloceCore"])],
    targets: [
        .target(name: "VeloceCore"),
        .executableTarget(name: "Veloce", dependencies: ["VeloceCore"]),
        .testTarget(name: "VeloceCoreTests", dependencies: ["VeloceCore"])
    ],
    swiftLanguageModes: [.v5]
)
