// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "riela",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "RielaCore", targets: ["RielaCore"]),
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
    .library(name: "CodexAgent", targets: ["CodexAgent"]),
    .library(name: "ClaudeCodeAgent", targets: ["ClaudeCodeAgent"]),
    .library(name: "CursorCLIAgent", targets: ["CursorCLIAgent"]),
    .executable(name: "codex-agent", targets: ["CodexAgentCLI"]),
    .executable(name: "claude-code-agent", targets: ["ClaudeCodeAgentCLI"]),
    .executable(name: "cursor-cli-agent", targets: ["CursorCLIAgentCLI"]),
    .executable(name: "riela", targets: ["RielaCLI"]),
    .executable(name: "RielaApp", targets: ["RielaApp"])
  ],
  dependencies: [
    .package(path: "Packages/RielaMemory"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.15.1")
  ],
  targets: [
    .target(
      name: "RielaJavaScript",
      linkerSettings: [
        .linkedFramework("JavaScriptCore", .when(platforms: [.macOS]))
      ]
    ),
    .target(
      name: "RielaCore",
      dependencies: [
        "RielaObservability",
        "RielaJavaScript",
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "RielaMemory", package: "RielaMemory")
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
      dependencies: ["RielaAddons", "RielaCore", "RielaEvents", "RielaServer", "RielaObservability"],
      resources: [.process("Resources")]
    ),
    .target(
      name: "CodexAgent",
      dependencies: [
        "RielaCore",
        "RielaAdapters",
        .product(name: "Crypto", package: "swift-crypto")
      ]
    ),
    .executableTarget(name: "CodexAgentCLI", dependencies: ["CodexAgent"]),
    .target(
      name: "ClaudeCodeAgent",
      dependencies: [
        "RielaCore",
        "RielaAdapters",
        .product(name: "Crypto", package: "swift-crypto")
      ]
    ),
    .executableTarget(name: "ClaudeCodeAgentCLI", dependencies: ["ClaudeCodeAgent"]),
    .target(
      name: "CursorCLIAgent",
      dependencies: [
        "RielaCore",
        "RielaAdapters",
        .product(name: "Crypto", package: "swift-crypto")
      ]
    ),
    .executableTarget(name: "CursorCLIAgentCLI", dependencies: ["CursorCLIAgent"]),
    .target(
      name: "RielaAdapters",
      dependencies: ["RielaCore"]
    ),
    .executableTarget(
      name: "RielaCLI",
      dependencies: [
        "RielaCore",
        .product(name: "RielaMemory", package: "RielaMemory"),
        "RielaAdapters",
        "RielaAddons",
        "RielaEvents",
        "RielaObservability",
        "RielaGraphQL",
        "RielaServer",
        "RielaHook",
        .product(name: "Crypto", package: "swift-crypto"),
        "CodexAgent",
        "ClaudeCodeAgent",
        "CursorCLIAgent"
      ]
    ),
    .executableTarget(
      name: "RielaApp",
      dependencies: [
        "RielaAppSupport",
        "RielaAdapters",
        "RielaCore",
        "CodexAgent",
        "ClaudeCodeAgent",
        "CursorCLIAgent",
        "RielaServer",
        "RielaViewer",
        "RielaObservability"
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
    .testTarget(name: "RielaJavaScriptTests", dependencies: ["RielaJavaScript"]),
    .testTarget(name: "RielaAddonsTests", dependencies: ["RielaCore", "RielaAddons"]),
    .testTarget(name: "RielaAdaptersTests", dependencies: ["RielaCore", "RielaAdapters"]),
    .testTarget(name: "RielaEventsTests", dependencies: ["RielaCore", "RielaEvents"]),
    .testTarget(name: "RielaHookTests", dependencies: ["RielaCore", "RielaHook"]),
    .testTarget(name: "RielaGraphQLTests", dependencies: ["RielaCore", "RielaGraphQL"]),
    .testTarget(name: "RielaServerTests", dependencies: ["RielaCore", "RielaGraphQL", "RielaServer", "RielaObservability"]),
    .testTarget(name: "RielaViewerTests", dependencies: ["RielaCore", "RielaViewer"]),
    .testTarget(name: "RielaAppSupportTests", dependencies: ["RielaAddons", "RielaAppSupport", "RielaServer", "RielaApp"]),
    .testTarget(name: "RielaCLITests", dependencies: ["RielaCore", "RielaAdapters", "RielaAppSupport", "RielaCLI"]),
    .testTarget(
      name: "AgentAdapterTests",
      dependencies: ["RielaCore", "RielaAdapters", "CodexAgent", "ClaudeCodeAgent", "CursorCLIAgent"]
    ),
    .testTarget(
      name: "CodexAgentTests",
      dependencies: ["RielaCore", "CodexAgent"]
    ),
    .testTarget(
      name: "ClaudeCodeAgentTests",
      dependencies: ["RielaCore", "ClaudeCodeAgent"]
    ),
    .testTarget(
      name: "CursorCLIAgentTests",
      dependencies: ["RielaCore", "CursorCLIAgent"]
    )
  ],
  swiftLanguageModes: [.v6]
)
