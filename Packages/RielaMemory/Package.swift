// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "RielaMemory",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "RielaMemory", targets: ["RielaMemory"])
  ],
  targets: [
    .target(name: "RielaMemory", dependencies: ["SQLite3"]),
    .systemLibrary(
      name: "SQLite3",
      providers: [
        .apt(["libsqlite3-dev"]),
        .brew(["sqlite"])
      ]
    ),
    .testTarget(name: "RielaMemoryTests", dependencies: ["RielaMemory"])
  ],
  swiftLanguageModes: [.v6]
)
