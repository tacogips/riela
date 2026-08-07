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
    .library(name: "AgentRuntimeKit", targets: ["AgentRuntimeKit"]),
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
    .executable(name: "riela", targets: ["RielaCLIExecutable"]),
    .executable(name: "RielaApp", targets: ["RielaApp"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.1"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
    .package(url: "https://github.com/tacogips/web-hooky.git", from: "0.2.0"),
    .package(url: "https://github.com/tacogips/kaiba.git", from: "0.1.1")
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
        "RielaSQLite",
        "RielaObservability",
        "RielaJavaScript",
        .product(name: "Crypto", package: "swift-crypto")
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
    .target(name: "AgentRuntimeKit", dependencies: ["RielaCore", "RielaSQLite"]),
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
        "AgentRuntimeKit",
        "RielaCore",
        "RielaAdapters",
        .product(name: "Crypto", package: "swift-crypto")
      ]
    ),
    .executableTarget(name: "CodexAgentCLI", dependencies: ["CodexAgent"]),
    .target(
      name: "ClaudeCodeAgent",
      dependencies: [
        "AgentRuntimeKit",
        "RielaCore",
        "RielaAdapters",
        .product(name: "Crypto", package: "swift-crypto")
      ]
    ),
    .executableTarget(name: "ClaudeCodeAgentCLI", dependencies: ["ClaudeCodeAgent"]),
    .target(
      name: "CursorCLIAgent",
      dependencies: [
        "AgentRuntimeKit",
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
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        "RielaCore",
        "RielaVersion",
        "RielaSQLite",
        .product(name: "AppCore", package: "kaiba"),
        .product(name: "AppGraphQL", package: "kaiba"),
        "RielaAdapters",
        "RielaAddons",
        "RielaEvents",
        "RielaObservability",
        "RielaGraphQL",
        "RielaServer",
        "RielaHook",
        "RielaWorkflowRegistry",
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "WebHooky", package: "web-hooky"),
        "CodexAgent",
        "ClaudeCodeAgent",
        "CursorCLIAgent"
      ]
    ),
    .executableTarget(name: "RielaCLIExecutable", dependencies: ["RielaCLI"]),
    .executableTarget(
      name: "RielaApp",
      dependencies: [
        "RielaAppSupport",
        "RielaAdapters",
        "RielaCore",
        "CodexAgent",
        "ClaudeCodeAgent",
        "CursorCLIAgent",
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
        "RielaObservability"
      ]
    ),
    .testTarget(name: "RielaSQLiteTests", dependencies: ["RielaSQLite"]),
    .testTarget(name: "AgentRuntimeKitTests", dependencies: ["AgentRuntimeKit", "RielaCore"]),
    .testTarget(name: "RielaJavaScriptTests", dependencies: ["RielaJavaScript"]),
    .testTarget(name: "RielaAddonsTests", dependencies: ["RielaCore", "RielaAddons"]),
    .testTarget(
      name: "RielaAdaptersTests",
      dependencies: ["RielaCore", "RielaAdapters"],
      resources: [.process("Resources")]
    ),
    .testTarget(name: "RielaEventsTests", dependencies: ["RielaCore", "RielaEvents"]),
    .testTarget(name: "RielaHookTests", dependencies: ["RielaCore", "RielaHook"]),
    .testTarget(name: "RielaGraphQLTests", dependencies: ["RielaCore", "RielaGraphQL"]),
    .testTarget(name: "RielaServerTests", dependencies: ["RielaCore", "RielaGraphQL", "RielaServer", "RielaObservability"]),
    .testTarget(name: "RielaViewerTests", dependencies: ["RielaCore", "RielaViewer"]),
    .testTarget(
      name: "RielaAppSupportTests",
      dependencies: [
        "RielaAddons",
        "RielaAppSupport",
        "RielaServer",
        "RielaApp",
        "RielaCLI",
      ]
    ),
    .testTarget(
      name: "RielaCLITests",
      dependencies: [
        "RielaCore",
        "RielaAdapters",
        "RielaAppSupport",
        "RielaCLI",
        "RielaWorkflowRegistry"
      ]
    ),
    .testTarget(
      name: "AgentAdapterTests",
      dependencies: ["RielaCore", "RielaAdapters", "CodexAgent", "ClaudeCodeAgent", "CursorCLIAgent"]
    ),
    .testTarget(
      name: "CodexAgentTests",
      dependencies: ["RielaCore", "RielaAdapters", "CodexAgent"]
    ),
    .testTarget(
      name: "ClaudeCodeAgentTests",
      dependencies: ["RielaCore", "RielaAdapters", "ClaudeCodeAgent"]
    ),
    .testTarget(
      name: "CursorCLIAgentTests",
      dependencies: ["RielaCore", "CursorCLIAgent"]
    )
  ],
  swiftLanguageModes: [.v6]
)
