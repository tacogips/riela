// swift-tools-version: 6.2

import PackageDescription

// Keep this value in sync with VERSION. It must be part of Package.swift because
// SwiftPM's manifest cache does not track files read dynamically by the manifest.
let rielaVersion = "0.2.20"

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
    .library(name: "RielaWork", targets: ["RielaWork"]),
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
    .executable(name: "riela-addon-worker", targets: ["RielaAddonWorkerExecutable"]),
    .executable(name: "RielaApp", targets: ["RielaApp"])
  ],
  dependencies: [
    .package(url: "https://github.com/tacogips/x-gateway.git", exact: "0.1.12"),
    .package(url: "https://github.com/tacogips/google-gateway-auth.git", revision: "48e0112fb5eb057cf012194cfffaa2581ba29d76"),
    .package(path: "Packages/RielaMemory"),
    .package(
      url: "https://github.com/tacogips/agent-gateway.git",
      revision: "dae69561f05b75be6d680af1267da1af9db16d13"
    ),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.2"),
    .package(url: "https://github.com/swift-server/swift-webauthn.git", exact: "1.0.0-beta.1"),
    .package(url: "https://github.com/unrelentingtech/SwiftCBOR.git", from: "0.6.0"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
    .package(url: "https://github.com/tacogips/web-hooky.git", from: "0.2.0"),
    .package(
      url: "https://github.com/tacogips/kaiba.git",
      revision: "24fc356a3073821c31866279c419abb707077a8d"
    ),
    .package(
      url: "https://github.com/tacogips/google-service-gateway.git",
      revision: "4cfef44b245893e6de4f30780c70fb0314da70eb"
    ),
    .package(
      url: "https://github.com/tacogips/wrike-gateway.git",
      revision: "8c67ad9452abdcad38924855bd1ae5a182a3dea2"
    ),
    .package(
      url: "https://github.com/tacogips/gmail-gateway.git",
      revision: "185cba5396d8afa43919f735c9329eb477b17418" // v0.1.22; SDK has revision-pinned dependencies.
    ),
    .package(
      url: "https://github.com/tacogips/google-analytics-gateway.git",
      revision: "3bd0048a01295ed3559da65b9aef9e767268a907"
    ),
    .package(
      url: "https://github.com/tacogips/apple-gateway.git",
      revision: "98229ed22f995e589ed6c42da553377615f11339" // v0.1.18; scoped Notes folder deletion and bounded native operations.
    ),
    .package(
      url: "https://github.com/tacogips/anydoc-swift.git",
      revision: "0aa4756d0ce3f97cc94f1de9efe26879808097c8"
    ),
    .package(
      url: "https://github.com/tacogips/google-documents-gateway.git",
      revision: "e97d952459305828461e3a808d0dfdace902079f"
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
    // The Work Runtime lifecycle (intents, tasks, attempts, decisions,
    // evidence). It depends on RielaCore and never the reverse: the runner
    // must stay usable without the task layer (design section 16).
    .target(
      name: "RielaWork",
      dependencies: [
        "RielaCore",
        "RielaSQLite",
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
    .target(name: "RielaObservability"),
    .target(
      name: "RielaAddons",
      dependencies: [
        "RielaCore",
        "RielaGraphQL",
        .product(name: "Crypto", package: "swift-crypto")
      ]
    ),
    // Template rendering and JSON coercion shared by every add-on family, kept
    // out of RielaCLI so add-on targets can depend on it without depending on
    // the CLI.
    .target(name: "RielaAddonSupport", dependencies: ["RielaCore"]),
    .target(
      name: "RielaKaibaSupport",
      dependencies: [
        "RielaCore",
        .product(name: "KaibaClient", package: "kaiba")
      ]
    ),
    // The only target that links Kaiba's dependency-free HTTP client. RielaCLI
    // sees a RielaCore-only façade (`KaibaAddonCatalog`); no Riela production
    // path imports Kaiba's service, GraphQL server, or storage modules.
    .target(
      name: "RielaKaibaAddons",
      dependencies: [
        "RielaAddonSupport",
        "RielaCore",
        "RielaKaibaSupport",
        .product(name: "KaibaClient", package: "kaiba"),
        .product(name: "Crypto", package: "swift-crypto")
      ]
    ),
    .target(name: "RielaEvents", dependencies: ["RielaCore"]),
    .target(name: "RielaGraphQL", dependencies: ["RielaCore"]),
    .target(name: "RielaServer", dependencies: [
      "RielaCore", "RielaGraphQL", "RielaObservability", "RielaWork",
      .product(name: "WebAuthn", package: "swift-webauthn"),
      .product(name: "SwiftCBOR", package: "SwiftCBOR"),
      .product(name: "Crypto", package: "swift-crypto")
    ]),
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
        "RielaKaibaSupport",
        "RielaEvents",
        "RielaServer",
        "RielaViewer",
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
        .product(name: "GoogleGatewayAuth", package: "google-gateway-auth"),
        .product(name: "XGatewayCore", package: "x-gateway", condition: .when(platforms: [.macOS])),
        // Gateway add-ons run inside this process; riela spawns no `*-gateway`
        // executable. The cumulative tier products carry every tier module, and
        // each add-on stays pinned to one tier through its role descriptor.
        // Wrike's pinned source supports Darwin and Linux. Other gateway
        // dependencies still require platform-specific build adaptations.
        .product(name: "WrikeGatewayAdmin", package: "wrike-gateway"),
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
        // Container builds explicitly enable Linux after provisioning its Rust
        // static library. Ordinary Linux CLI builds need no Rust dependency.
        .product(name: "AnydocKit", package: "anydoc-swift", condition: .when(platforms: [.macOS])),
        .product(name: "AppleGatewayCore", package: "apple-gateway", condition: .when(platforms: [.macOS])),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        "RielaCore",
        "RielaWork",
        "RielaAppSupport",
        "RielaVersion",
        "RielaSQLite",
        .product(name: "RielaMemory", package: "RielaMemory"),
        "RielaAdapters",
        "RielaAddons",
        "RielaAddonSupport",
        "RielaKaibaSupport",
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
      name: "RielaAddonWorkerExecutable",
      dependencies: ["RielaCLI"],
      linkerSettings: rielaInfoPlistLinkerSettings
    ),
    .executableTarget(
      name: "RielaApp",
      dependencies: [
        "RielaCLI",
        "RielaAppSupport",
        "RielaKaibaSupport",
        "RielaAdapters",
        "RielaCore",
        "RielaGraphQL",
        "RielaServer",
        "RielaViewer",
        "RielaObservability",
        "RielaWorkflowRegistry"
      ],
      resources: [.process("Resources")],
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
    .testTarget(
      name: "RielaWorkTests",
      dependencies: ["RielaWork", "RielaCore"],
      resources: [.copy("Fixtures")]
    ),
    .testTarget(name: "RielaSQLiteTests", dependencies: ["RielaSQLite"]),
    .testTarget(name: "RielaJavaScriptTests", dependencies: ["RielaJavaScript"]),
    .testTarget(name: "RielaAddonsTests", dependencies: ["RielaCore", "RielaAddons", .product(name: "Crypto", package: "swift-crypto")]),
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
    .testTarget(
      name: "RielaKaibaSupportTests",
      dependencies: ["RielaCore", "RielaKaibaSupport"]
    ),
    .testTarget(name: "RielaHookTests", dependencies: ["RielaCore", "RielaHook"]),
    .testTarget(name: "RielaGraphQLTests", dependencies: ["RielaCore", "RielaGraphQL"]),
    .testTarget(name: "RielaServerTests", dependencies: ["RielaCore", "RielaGraphQL", "RielaServer", "RielaObservability", "RielaWork"]),
    .testTarget(name: "RielaViewerTests", dependencies: ["RielaCore", "RielaViewer"]),
    .testTarget(
      name: "RielaAppSupportTests",
      dependencies: [
        .product(name: "AgentGateway", package: "agent-gateway"),
        .product(name: "AgentGatewayAppCore", package: "agent-gateway"),
        "RielaAddons",
        "RielaAppSupport",
        "RielaKaibaSupport",
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
        "RielaAddonSupport",
        "RielaEvents",
        "RielaAdapters",
        "RielaAppSupport",
        "RielaCLI",
        "RielaKaibaSupport",
        "RielaServer",
        "RielaWorkflowRegistry",
        .product(name: "GoogleServiceGatewayCore", package: "google-service-gateway")
      ]
    )
  ],
  swiftLanguageModes: [.v6]
)
