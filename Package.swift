// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Veloce",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Veloce", targets: ["Veloce"]), .library(name: "VeloceCore", targets: ["VeloceCore"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "VeloceCore"),
        .executableTarget(name: "Veloce", dependencies: ["VeloceCore", .product(name: "Sparkle", package: "Sparkle")]),
        .testTarget(name: "VeloceCoreTests", dependencies: ["VeloceCore"])
    ],
    swiftLanguageModes: [.v5]
)
