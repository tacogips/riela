// swift-tools-version: 6.0

import Foundation
import PackageDescription

let rielaVersionFileURL = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .appendingPathComponent("VERSION")
let rielaVersion = try String(contentsOf: rielaVersionFileURL, encoding: .utf8)
  .trimmingCharacters(in: .whitespacesAndNewlines)

let package = Package(
  name: "riela",
  platforms: [
    .macOS(.v14),
    .iOS(.v17)
  ],
  products: [
    .library(name: "RielaCore", targets: ["RielaCore"]),
    .library(name: "RielaSQLite", targets: ["RielaSQLite"]),
    .library(name: "RielaJavaScript", targets: ["RielaJavaScript"]),
    .library(name: "RielaAddons", targets: ["RielaAddons"]),
    .library(name: "RielaAdapters", targets: ["RielaAdapters"]),
    .library(name: "RielaEvents", targets: ["RielaEvents"]),
    .library(name: "RielaObservability", targets: ["RielaObservability"]),
    .library(name: "RielaGraphQL", targets: ["RielaGraphQL"]),
    .library(name: "RielaServer", targets: ["RielaServer"]),
    .library(name: "RielaViewer", targets: ["RielaViewer"]),
    .library(name: "RielaHook", targets: ["RielaHook"]),
    .library(name: "RielaAppSupport", targets: ["RielaAppSupport"]),
    .executable(name: "riela", targets: ["RielaCLIExecutable"]),
    .executable(name: "RielaApp", targets: ["RielaApp"])
  ],
  dependencies: [
    .package(path: "Packages/RielaMemory"),
    .package(
      url: "https://github.com/tacogips/agent-gateway.git",
      revision: "2ddea8aaa66567ec6b4f01d9eb9eca1077014315"
    ),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.1"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
    .package(url: "https://github.com/tacogips/web-hooky.git", from: "0.2.0"),
    .package(
      url: "https://github.com/tacogips/kaiba.git",
      revision: "5614bf27cabf0584ff5101256da3b5c81d82533e"
    ),
    .package(
      url: "https://github.com/tacogips/google-service-gateway.git",
      revision: "0c4ffa2a2f7fad777bf28540517bf0938699b943"
    )
  ],
  targets: [
    .target(
      name: "RielaJavaScript",
      linkerSettings: [
        .linkedFramework("JavaScriptCore", .when(platforms: [.macOS]))
      ]
    ),
    .target(
      name: "RielaVersion",
      publicHeadersPath: "include",
      cSettings: [.define("RIELA_EMBEDDED_VERSION", to: "\"\(rielaVersion)\"")]
    ),
    .target(
      name: "RielaCore",
      dependencies: [
        .product(name: "AgentGateway", package: "agent-gateway"),
        "RielaSQLite",
        "RielaObservability",
        "RielaJavaScript",
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "RielaMemory", package: "RielaMemory")
      ]
    ),
    .target(
      name: "RielaSQLite",
      dependencies: [
        .target(name: "CRielaSQLite3", condition: .when(platforms: [.linux]))
      ]
    ),
    .systemLibrary(
      name: "CRielaSQLite3",
      providers: [
        .apt(["libsqlite3-dev"]),
        .brew(["sqlite"])
      ]
    ),
    .target(name: "RielaObservability"),
    .target(
      name: "RielaAddons",
      dependencies: [
        "RielaCore",
        .product(name: "Crypto", package: "swift-crypto")
      ]
    ),
    // Template rendering and JSON coercion shared by every add-on family, kept
    // out of RielaCLI so add-on targets can depend on it without depending on
    // the CLI.
    .target(name: "RielaAddonSupport", dependencies: ["RielaCore"]),
    // The only target that links kaiba. Everything kaiba-typed — its note
    // service, its identifiers, its JSON model — stops here; RielaCLI sees a
    // RielaCore-only façade (`KaibaAddonCatalog`).
    .target(
      name: "RielaKaibaAddons",
      dependencies: [
        "RielaAddonSupport",
        "RielaCore",
        .product(name: "AppCore", package: "kaiba"),
        .product(name: "AppGraphQL", package: "kaiba"),
        .product(name: "Crypto", package: "swift-crypto")
      ]
    ),
    .target(name: "RielaEvents", dependencies: ["RielaCore"]),
    .target(name: "RielaGraphQL", dependencies: ["RielaCore"]),
    .target(name: "RielaServer", dependencies: ["RielaCore", "RielaGraphQL", "RielaObservability"]),
    .target(name: "RielaViewer", dependencies: ["RielaCore"]),
    .target(
      name: "RielaHook",
      dependencies: [
        "RielaCore",
        .product(name: "Crypto", package: "swift-crypto")
      ]
    ),
    .target(
      name: "RielaAppSupport",
      dependencies: [
        .product(name: "AgentGateway", package: "agent-gateway"),
        .product(name: "AgentGatewayAppCore", package: "agent-gateway"),
        "RielaAddons",
        "RielaCore",
        "RielaEvents",
        "RielaServer",
        "RielaObservability"
      ],
      resources: [.process("Resources")]
    ),
    .target(
      name: "RielaAdapters",
      dependencies: [
        .product(name: "ACP", package: "agent-gateway"),
        .product(name: "AgentGateway", package: "agent-gateway"),
        "RielaCore"
      ]
    ),
    .target(
      name: "RielaWorkflowRegistry",
      dependencies: [
        "RielaAddons",
        "RielaCore",
        "RielaGraphQL",
        .product(name: "Crypto", package: "swift-crypto")
      ]
    ),
    .target(
      name: "RielaCLI",
      dependencies: [
        .product(name: "ACP", package: "agent-gateway"),
        .product(name: "AgentGateway", package: "agent-gateway"),
        .product(name: "GoogleServiceGatewayCore", package: "google-service-gateway"),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        "RielaCore",
        "RielaVersion",
        "RielaSQLite",
        .product(name: "RielaMemory", package: "RielaMemory"),
        "RielaAdapters",
        "RielaAddons",
        "RielaAddonSupport",
        "RielaKaibaAddons",
        "RielaEvents",
        "RielaObservability",
        "RielaGraphQL",
        "RielaServer",
        "RielaHook",
        "RielaWorkflowRegistry",
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "WebHooky", package: "web-hooky")
      ]
    ),
    .executableTarget(name: "RielaCLIExecutable", dependencies: ["RielaCLI"]),
    .executableTarget(
      name: "RielaApp",
      dependencies: [
        "RielaAppSupport",
        "RielaAdapters",
        "RielaCore",
        "RielaGraphQL",
        "RielaServer",
        "RielaViewer",
        "RielaObservability",
        "RielaWorkflowRegistry"
      ]
    ),
    .testTarget(
      name: "RielaCoreTests",
      dependencies: [
        "RielaCore",
        "RielaObservability",
        .product(name: "RielaMemory", package: "RielaMemory")
      ]
    ),
    .testTarget(name: "RielaSQLiteTests", dependencies: ["RielaSQLite"]),
    .testTarget(name: "RielaJavaScriptTests", dependencies: ["RielaJavaScript"]),
    .testTarget(name: "RielaAddonsTests", dependencies: ["RielaCore", "RielaAddons"]),
    .testTarget(
      name: "RielaAdaptersTests",
      dependencies: [
        .product(name: "ACP", package: "agent-gateway"),
        .product(name: "AgentGateway", package: "agent-gateway"),
        "RielaCore",
        "RielaAdapters"
      ]
    ),
    .testTarget(name: "RielaEventsTests", dependencies: ["RielaCore", "RielaEvents"]),
    .testTarget(name: "RielaHookTests", dependencies: ["RielaCore", "RielaHook"]),
    .testTarget(name: "RielaGraphQLTests", dependencies: ["RielaCore", "RielaGraphQL"]),
    .testTarget(name: "RielaServerTests", dependencies: ["RielaCore", "RielaGraphQL", "RielaServer", "RielaObservability"]),
    .testTarget(name: "RielaViewerTests", dependencies: ["RielaCore", "RielaViewer"]),
    .testTarget(
      name: "RielaAppSupportTests",
      dependencies: [
        .product(name: "AgentGateway", package: "agent-gateway"),
        .product(name: "AgentGatewayAppCore", package: "agent-gateway"),
        "RielaAddons",
        "RielaAppSupport",
        "RielaServer",
        "RielaApp",
        "RielaCLI"
      ]
    ),
    .testTarget(
      name: "RielaKaibaAddonsTests",
      dependencies: [
        "RielaCore",
        // RielaAddons never links kaiba; it is here so the parity test can
        // pin its hand-maintained descriptor list to the catalog.
        "RielaAddons",
        "RielaKaibaAddons",
        .product(name: "AppCore", package: "kaiba"),
        .product(name: "AppGraphQL", package: "kaiba")
      ]
    ),
    .testTarget(
      name: "RielaCLITests",
      dependencies: [
        "RielaCore",
        "RielaAdapters",
        "RielaAppSupport",
        "RielaCLI",
        "RielaWorkflowRegistry",
        .product(name: "GoogleServiceGatewayCore", package: "google-service-gateway")
      ]
    )
  ],
  swiftLanguageModes: [.v6]
)
