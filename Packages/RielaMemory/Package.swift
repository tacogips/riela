// swift-tools-version: 6.1

import PackageDescription

let package = Package(
  name: "RielaMemory",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "RielaMemory", targets: ["RielaMemory"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.2")
  ],
  targets: [
    .target(
      name: "RielaMemory",
      dependencies: [
        .product(name: "Crypto", package: "swift-crypto"),
        .target(name: "SQLite3", condition: .when(platforms: [.linux]))
      ]
    ),
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
