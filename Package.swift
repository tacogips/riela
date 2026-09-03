// swift-tools-version: 6.0

import Foundation
import PackageDescription

let rielaVersionFileURL = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .appendingPathComponent("VERSION")
let rielaVersion = try String(contentsOf: rielaVersionFileURL, encoding: .utf8)
  .trimmingCharacters(in: .whitespacesAndNewlines)

// The riela executables call apple-gateway as a linked library, and macOS
// attaches TCC permission grants to the calling executable's own identity. The
// section below gives riela its own bundle identifier and usage strings, so
// the Apple Events / Calendars / Reminders / Contacts prompts name riela
// rather than borrowing another tool's wording. Only Apple platforms embed it.
let rielaInfoPlistLinkerSettings: [LinkerSetting] = [
  .unsafeFlags(
    [
      "-Xlinker", "-sectcreate",
      "-Xlinker", "__TEXT",
      "-Xlinker", "__info_plist",
      "-Xlinker", "Resources/RielaInfo.plist"
    ],
    .when(platforms: [.macOS])
  )
]

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
      revision: "0a28f04d91f5149cead7aa96b048bed1e3be737c"
    ),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.1"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
    .package(url: "https://github.com/tacogips/web-hooky.git", from: "0.2.0"),
    .package(
      url: "https://github.com/tacogips/kaiba.git",
      revision: "31f23145d26f87803d7c10984969f937a6926ff7"
    ),
    .package(
      url: "https://github.com/tacogips/google-service-gateway.git",
      revision: "3d964e69b3342cb70726f668f4600832421f7bf9"
    ),
    .package(
      url: "https://github.com/tacogips/wrike-gateway.git",
      revision: "d607aaa6783fef2b34c1a73ec9e091ef421143bf"
    ),
    .package(
      url: "https://github.com/tacogips/gmail-gateway.git",
      revision: "2761f3bccf30ead78de5d6968d827929925eae80"
    ),
    .package(
      url: "https://github.com/tacogips/google-analytics-gateway.git",
      revision: "c46443a5e8f744244cb9825d3238958a797c4f2b"
    ),
    .package(
      url: "https://github.com/tacogips/apple-gateway.git",
      revision: "3a2320ef74aa40c6ee42852b10f48f3c3911b917"
    ),
    .package(
      url: "https://github.com/tacogips/anydoc-swift.git",
      revision: "d957c08372786b7062553e83fe9c29880fdee7a4"
    ),
    .package(
      url: "https://github.com/tacogips/google-documents-gateway.git",
      revision: "cda93cdd770a51f6f9d1bc63b1db555884824606"
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
        // The gateway agent runs inside this process; riela never spawns the
        // `agent-gateway` executable.
        .product(name: "AgentGatewayAppCore", package: "agent-gateway"),
        "RielaCore",
        "RielaVersion"
      ]
    ),
    .target(
      name: "RielaWorkflowRegistry",
      dependencies: [
        "RielaAddons",
        "RielaCore",
        "RielaEvents",
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
        // Gateway add-ons run inside this process; riela spawns no `*-gateway`
        // executable. The cumulative tier products carry every tier module, and
        // each add-on stays pinned to one tier through its role descriptor.
        // These gateways use Darwin, Security, Network, and AppKit without
        // portability guards, so they are macOS-only; the add-ons that call
        // them refuse to run elsewhere.
        .product(name: "WrikeGatewayAdmin", package: "wrike-gateway", condition: .when(platforms: [.macOS])),
        .product(name: "GmailGatewayCore", package: "gmail-gateway", condition: .when(platforms: [.macOS])),
        .product(
          name: "GoogleAnalyticsGatewayAdmin",
          package: "google-analytics-gateway",
          condition: .when(platforms: [.macOS])
        ),
        .product(
          name: "GoogleDocumentsGatewayCore",
          package: "google-documents-gateway",
          condition: .when(platforms: [.macOS])
        ),
        // The document converter is the same native library kaiba already
        // links. Its Linux route is a pkg-config staticlib that has to be
        // built from Rust, so — like kaiba — the dependency is conditional and
        // the add-on refuses to run where the converter is unavailable.
        .product(name: "AnydocKit", package: "anydoc-swift", condition: .when(platforms: [.macOS])),
        .product(name: "AppleGatewayCore", package: "apple-gateway", condition: .when(platforms: [.macOS])),
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
    .executableTarget(
      name: "RielaCLIExecutable",
      dependencies: ["RielaCLI"],
      linkerSettings: rielaInfoPlistLinkerSettings
    ),
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
      ],
      linkerSettings: rielaInfoPlistLinkerSettings
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
        .product(name: "AgentGatewayAppCore", package: "agent-gateway"),
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
        "RielaEvents",
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
