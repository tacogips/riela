// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "riela",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "RielaCore", targets: ["RielaCore"]),
    .library(name: "RielaAddons", targets: ["RielaAddons"]),
    .library(name: "RielaAdapters", targets: ["RielaAdapters"]),
    .library(name: "RielaEvents", targets: ["RielaEvents"]),
    .library(name: "RielaGraphQL", targets: ["RielaGraphQL"]),
    .library(name: "RielaServer", targets: ["RielaServer"]),
    .library(name: "RielaViewer", targets: ["RielaViewer"]),
    .library(name: "RielaHook", targets: ["RielaHook"]),
    .library(name: "CodexAgent", targets: ["CodexAgent"]),
    .library(name: "ClaudeCodeAgent", targets: ["ClaudeCodeAgent"]),
    .library(name: "CursorCLIAgent", targets: ["CursorCLIAgent"]),
    .executable(name: "codex-agent", targets: ["CodexAgentCLI"]),
    .executable(name: "claude-code-agent", targets: ["ClaudeCodeAgentCLI"]),
    .executable(name: "cursor-cli-agent", targets: ["CursorCLIAgentCLI"]),
    .executable(name: "riela", targets: ["RielaCLI"]),
    .executable(name: "RielaApp", targets: ["RielaApp"])
  ],
  targets: [
    .target(name: "RielaCore"),
    .target(name: "RielaAddons", dependencies: ["RielaCore"]),
    .target(name: "RielaEvents", dependencies: ["RielaCore"]),
    .target(name: "RielaGraphQL", dependencies: ["RielaCore"]),
    .target(name: "RielaServer", dependencies: ["RielaCore", "RielaGraphQL"]),
    .target(name: "RielaViewer", dependencies: ["RielaCore"]),
    .target(name: "RielaHook", dependencies: ["RielaCore"]),
    .target(name: "CodexAgent", dependencies: ["RielaCore", "RielaAdapters"]),
    .executableTarget(name: "CodexAgentCLI", dependencies: ["CodexAgent"]),
    .target(name: "ClaudeCodeAgent", dependencies: ["RielaCore", "RielaAdapters"]),
    .executableTarget(name: "ClaudeCodeAgentCLI", dependencies: ["ClaudeCodeAgent"]),
    .target(name: "CursorCLIAgent", dependencies: ["RielaCore", "RielaAdapters"]),
    .executableTarget(name: "CursorCLIAgentCLI", dependencies: ["CursorCLIAgent"]),
    .target(
      name: "RielaAdapters",
      dependencies: ["RielaCore"]
    ),
    .executableTarget(
      name: "RielaCLI",
      dependencies: [
        "RielaCore",
        "RielaAdapters",
        "RielaAddons",
        "RielaEvents",
        "RielaGraphQL",
        "RielaServer",
        "RielaHook",
        "CodexAgent",
        "ClaudeCodeAgent",
        "CursorCLIAgent"
      ]
    ),
    .executableTarget(
      name: "RielaApp",
      dependencies: [
        "RielaServer",
        "RielaViewer"
      ]
    ),
    .testTarget(name: "RielaCoreTests", dependencies: ["RielaCore"]),
    .testTarget(name: "RielaAddonsTests", dependencies: ["RielaCore", "RielaAddons"]),
    .testTarget(name: "RielaAdaptersTests", dependencies: ["RielaCore", "RielaAdapters"]),
    .testTarget(name: "RielaEventsTests", dependencies: ["RielaCore", "RielaEvents"]),
    .testTarget(name: "RielaHookTests", dependencies: ["RielaCore", "RielaHook"]),
    .testTarget(name: "RielaGraphQLTests", dependencies: ["RielaCore", "RielaGraphQL"]),
    .testTarget(name: "RielaServerTests", dependencies: ["RielaCore", "RielaGraphQL", "RielaServer"]),
    .testTarget(name: "RielaViewerTests", dependencies: ["RielaCore", "RielaViewer"]),
    .testTarget(name: "RielaCLITests", dependencies: ["RielaCore", "RielaAdapters", "RielaCLI"]),
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
