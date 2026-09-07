// swift-tools-version: 6.0

import PackageDescription

var products: [Product] = [
  .library(name: "DockVacCore", targets: ["DockVacCore"]),
  .library(name: "DockVacDocker", targets: ["DockVacDocker"]),
]

var targets: [Target] = [
  .target(
    name: "DockVacCore",
    swiftSettings: [.swiftLanguageMode(.v6)]
  ),
  .target(
    name: "DockVacDocker",
    dependencies: ["DockVacCore"],
    swiftSettings: [.swiftLanguageMode(.v6)]
  ),
  .testTarget(
    name: "DockVacCoreTests",
    dependencies: ["DockVacCore"],
    resources: [.copy("Fixtures")],
    swiftSettings: [.swiftLanguageMode(.v6)]
  ),
  .testTarget(
    name: "DockVacDockerTests",
    dependencies: ["DockVacDocker", "DockVacCore"],
    swiftSettings: [.swiftLanguageMode(.v6)]
  ),
]

#if os(macOS)
  products.append(.executable(name: "DockVac", targets: ["DockVac"]))
  targets.append(
    .executableTarget(
      name: "DockVac",
      dependencies: ["DockVacCore", "DockVacDocker"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ))
#endif

let package = Package(
  name: "DockVac",
  platforms: [.macOS(.v13)],
  products: products,
  targets: targets
)
