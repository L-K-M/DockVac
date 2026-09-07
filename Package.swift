// swift-tools-version: 6.0

import PackageDescription

var products: [Product] = [
  .library(name: "DockVacCore", targets: ["DockVacCore"])
]

var targets: [Target] = [
  .target(
    name: "DockVacCore",
    swiftSettings: [.swiftLanguageMode(.v6)]
  ),
  .testTarget(
    name: "DockVacCoreTests",
    dependencies: ["DockVacCore"],
    swiftSettings: [.swiftLanguageMode(.v6)]
  ),
]

#if os(macOS)
  products.append(.executable(name: "DockVac", targets: ["DockVac"]))
  targets.append(.executableTarget(name: "DockVac", dependencies: ["DockVacCore"]))
#endif

let package = Package(
  name: "DockVac",
  platforms: [.macOS(.v13)],
  products: products,
  targets: targets,
  swiftLanguageModes: [.v5]
)
