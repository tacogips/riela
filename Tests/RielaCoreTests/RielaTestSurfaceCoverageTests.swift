import Foundation
import XCTest

final class RielaTestSurfaceCoverageTests: XCTestCase {
  private static let sourceTests: Set<String> = [
    "packages/riela/src/cli.test.ts",
    "packages/riela/src/events/adapter-registry.test.ts",
    "packages/riela/src/events/adapters/chat-sdk.test.ts",
    "packages/riela/src/events/adapters/cron.test.ts",
    "packages/riela/src/events/adapters/discord-gateway.test.ts",
    "packages/riela/src/events/adapters/file-change.test.ts",
    "packages/riela/src/events/adapters/matrix.test.ts",
    "packages/riela/src/events/adapters/s3-repository.test.ts",
    "packages/riela/src/events/adapters/sequential-list.test.ts",
    "packages/riela/src/events/adapters/telegram-gateway.test.ts",
    "packages/riela/src/events/adapters/webhook.test.ts",
    "packages/riela/src/events/chat-agent-trio-parity-example.test.ts",
    "packages/riela/src/events/chat-reply-example.test.ts",
    "packages/riela/src/events/config.test.ts",
    "packages/riela/src/events/dispatch-supervisor-chat.test.ts",
    "packages/riela/src/events/external-output.test.ts",
    "packages/riela/src/events/input-mapping.test.ts",
    "packages/riela/src/events/listener-service.test.ts",
    "packages/riela/src/events/mailbox-bridge-policy.test.ts",
    "packages/riela/src/events/manual-emit.test.ts",
    "packages/riela/src/events/matrix-chat-reply-example.test.ts",
    "packages/riela/src/events/receipt-ops.test.ts",
    "packages/riela/src/events/reply-dispatcher.test.ts",
    "packages/riela/src/events/scheduled-event-manager.test.ts",
    "packages/riela/src/events/sequential-list-completion.test.ts",
    "packages/riela/src/events/session-stickiness.test.ts",
    "packages/riela/src/events/supervised-runs.test.ts",
    "packages/riela/src/events/supervisor-command-contract.test.ts",
    "packages/riela/src/events/supervisor-control-reply.test.ts",
    "packages/riela/src/events/supervisor-conversations.test.ts",
    "packages/riela/src/events/supervisor-dispatch-contract.test.ts",
    "packages/riela/src/events/supervisor-intent.test.ts",
    "packages/riela/src/events/supervisor-llm-batch.test.ts",
    "packages/riela/src/events/supervisor-llm-intent.test.ts",
    "packages/riela/src/events/supervisor-llm-resolver-dispatch.test.ts",
    "packages/riela/src/events/supervisor-profiles.test.ts",
    "packages/riela/src/events/trigger-runner-options.test.ts",
    "packages/riela/src/events/trigger-runner-stickiness.test.ts",
    "packages/riela/src/events/trigger-runner-supervised.test.ts",
    "packages/riela/src/events/trigger-runner-supervisor-dispatch.test.ts",
    "packages/riela/src/events/validate-source-sequential-list.test.ts",
    "packages/riela/src/events/workflow-schedule-dispatch.test.ts",
    "packages/riela/src/events/workflow-schedule-registration.test.ts",
    "packages/riela/src/events/workflow-schedule-registry.test.ts",
    "packages/riela/src/graphql/schema.test.ts",
    "packages/riela/src/hook/config.test.ts",
    "packages/riela/src/hook/index.test.ts",
    "packages/riela/src/lib-api.test.ts",
    "packages/riela/src/lib-supervision.test.ts",
    "packages/riela/src/package-boundaries.test.ts",
    "packages/riela/src/server/api.test.ts",
    "packages/riela/src/server/graphql-auth.test.ts",
    "packages/riela/src/server/graphql-execution-overview-and-definitions.test.ts",
    "packages/riela/src/server/graphql-queries-and-inspection.test.ts",
    "packages/riela/src/server/graphql-supervision-and-resume.test.ts",
    "packages/riela/src/server/serve.test.ts",
    "packages/riela/src/shared/fs.test.ts",
    "packages/riela/src/shared/json.test.ts",
    "packages/riela/src/telemetry/config.test.ts",
    "packages/riela/src/telemetry/redaction.test.ts",
    "packages/riela/src/telemetry/tracing.test.ts",
    "packages/riela/src/workflow/adapter.test.ts",
    "packages/riela/src/workflow/adapters/anthropic-sdk.test.ts",
    "packages/riela/src/workflow/adapters/claude.test.ts",
    "packages/riela/src/workflow/adapters/cli-agent-live-smoke.test.ts",
    "packages/riela/src/workflow/adapters/codex.test.ts",
    "packages/riela/src/workflow/adapters/cursor-sdk.test.ts",
    "packages/riela/src/workflow/adapters/cursor.test.ts",
    "packages/riela/src/workflow/adapters/dispatch.test.ts",
    "packages/riela/src/workflow/adapters/official-sdk-live-smoke.test.ts",
    "packages/riela/src/workflow/adapters/openai-sdk.test.ts",
    "packages/riela/src/workflow/adapters/readiness.test.ts",
    "packages/riela/src/workflow/adapters/shared.test.ts",
    "packages/riela/src/workflow/addon-package-boundary.test.ts",
    "packages/riela/src/workflow/authored-workflow.test.ts",
    "packages/riela/src/workflow/auto-improve-policy.test.ts",
    "packages/riela/src/workflow/backend.test.ts",
    "packages/riela/src/workflow/call-step-impl-execution.test.ts",
    "packages/riela/src/workflow/call-step-impl-failures.test.ts",
    "packages/riela/src/workflow/call-step.test.ts",
    "packages/riela/src/workflow/catalog.test.ts",
    "packages/riela/src/workflow/checkout/checkout.test.ts",
    "packages/riela/src/workflow/codex-model-check-message.test.ts",
    "packages/riela/src/workflow/communication-service.test.ts",
    "packages/riela/src/workflow/create.test.ts",
    "packages/riela/src/workflow/cross-workflow-from-steps.test.ts",
    "packages/riela/src/workflow/engine-fanout.test.ts",
    "packages/riela/src/workflow/engine.test.ts",
    "packages/riela/src/workflow/examples-script-contract.test.ts",
    "packages/riela/src/workflow/history-continuation.test.ts",
    "packages/riela/src/workflow/history.test.ts",
    "packages/riela/src/workflow/input-assembly.test.ts",
    "packages/riela/src/workflow/inspect.test.ts",
    "packages/riela/src/workflow/json-schema.test.ts",
    "packages/riela/src/workflow/load.test.ts",
    "packages/riela/src/workflow/manager-control.test.ts",
    "packages/riela/src/workflow/manager-message-service.test.ts",
    "packages/riela/src/workflow/manager-session-store.test.ts",
    "packages/riela/src/workflow/manifest.test.ts",
    "packages/riela/src/workflow/mutable-workspace.test.ts",
    "packages/riela/src/workflow/native-node-executor-addons-commands.test.ts",
    "packages/riela/src/workflow/native-node-executor-gateway.test.ts",
    "packages/riela/src/workflow/node-addons/sdk-agent-workers.test.ts",
    "packages/riela/src/workflow/overview.test.ts",
    "packages/riela/src/workflow/packages/checkout.test.ts",
    "packages/riela/src/workflow/packages/packages.test.ts",
    "packages/riela/src/workflow/paths.test.ts",
    "packages/riela/src/workflow/prompt-composition.test.ts",
    "packages/riela/src/workflow/render.test.ts",
    "packages/riela/src/workflow/revision.test.ts",
    "packages/riela/src/workflow/runtime-addressing.test.ts",
    "packages/riela/src/workflow/runtime-db.test.ts",
    "packages/riela/src/workflow/runtime-db/file-handle-copy.test.ts",
    "packages/riela/src/workflow/runtime-execution-contracts.test.ts",
    "packages/riela/src/workflow/runtime-readiness-agent-probes.test.ts",
    "packages/riela/src/workflow/runtime-readiness-backends.test.ts",
    "packages/riela/src/workflow/runtime-readiness-cross-workflow.test.ts",
    "packages/riela/src/workflow/save.test.ts",
    "packages/riela/src/workflow/scenario-adapter.test.ts",
    "packages/riela/src/workflow/self-improve/backup-git.test.ts",
    "packages/riela/src/workflow/self-improve/backup.test.ts",
    "packages/riela/src/workflow/self-improve/config.test.ts",
    "packages/riela/src/workflow/self-improve/patcher.test.ts",
    "packages/riela/src/workflow/self-improve/pathing.test.ts",
    "packages/riela/src/workflow/self-improve/report.test.ts",
    "packages/riela/src/workflow/self-improve/service.test.ts",
    "packages/riela/src/workflow/self-improve/source-selection.test.ts",
    "packages/riela/src/workflow/semantics.test.ts",
    "packages/riela/src/workflow/session-health.test.ts",
    "packages/riela/src/workflow/session-history.test.ts",
    "packages/riela/src/workflow/session-id.test.ts",
    "packages/riela/src/workflow/session-store.test.ts",
    "packages/riela/src/workflow/session.test.ts",
    "packages/riela/src/workflow/sleep-node-runtime.test.ts",
    "packages/riela/src/workflow/superviser-control.test.ts",
    "packages/riela/src/workflow/superviser-runtime-control-impl.test.ts",
    "packages/riela/src/workflow/superviser.test.ts",
    "packages/riela/src/workflow/supervisor-client.test.ts",
    "packages/riela/src/workflow/supervisor-graphql-client.test.ts",
    "packages/riela/src/workflow/supervisor-progress-renderer.test.ts",
    "packages/riela/src/workflow/supervisor-runner-pool.test.ts",
    "packages/riela/src/workflow/types.test.ts",
    "packages/riela/src/workflow/user-backend-session-store.test.ts",
    "packages/riela/src/workflow/validate.test.ts",
    "packages/riela/src/workflow/visualization.test.ts",
    "packages/riela/src/workflow/working-directory.test.ts",
    "scripts/check-source-filenames.test.ts"
  ]

  private static let equivalentSwiftTests: [String: [String]] = [
    "agent-adapters": [
      "Tests/RielaAdaptersTests/OfficialSDKAdapterTests.swift",
      "Tests/RielaAdaptersTests/WorkflowStdioNodeExecutorTests.swift",
      "Tests/AgentAdapterTests/AgentAdapterTests.swift",
      "Tests/CodexAgentTests/CodexAgentCompatibilityTests.swift",
      "Tests/ClaudeCodeAgentTests/ClaudeCodeAgentCompatibilityTests.swift",
      "Tests/CursorCLIAgentTests/CursorCLIAgentCompatibilityTests.swift"
    ],
    "cli": [
      "Tests/RielaCLITests/CommandParsingTests.swift",
      "Tests/RielaCLITests/WorkflowCommandTests.swift"
    ],
    "events": [
      "Tests/RielaEventsTests/EventDryRunTests.swift"
    ],
    "events-adapters": [
      "Tests/RielaEventsTests/EventDryRunTests.swift"
    ],
    "graphql": [
      "Tests/RielaGraphQLTests/GraphQLContractsTests.swift"
    ],
    "hook": [
      "Tests/RielaHookTests/HookContractsTests.swift"
    ],
    "library-api": [
      "Tests/RielaCoreTests/SwiftDeletionReadinessTests.swift",
      "Tests/RielaCLITests/WorkflowCommandTests.swift"
    ],
    "native-addons": [
      "Tests/RielaAddonsTests/AddonExecutionContractsTests.swift",
      "Tests/RielaAddonsTests/NativeBundleAddonContractsTests.swift",
      "Tests/RielaAddonsTests/NativeBundleAddonResolverTests.swift"
    ],
    "packages": [
      "Tests/RielaAddonsTests/WorkflowPackageManifestTests.swift",
      "Tests/RielaCLITests/WorkflowCommandTests.swift"
    ],
    "runtime-db": [
      "Tests/RielaCoreTests/RuntimeStoreTests.swift",
      "Tests/RielaCoreTests/RuntimeSessionTests.swift"
    ],
    "self-improve": [
      "Tests/RielaCLITests/WorkflowCommandTests.swift"
    ],
    "server": [
      "Tests/RielaServerTests/ServerContractsTests.swift"
    ],
    "shared": [
      "Tests/RielaCoreTests/WorkflowModelTests.swift",
      "Tests/RielaCoreTests/RuntimeOutputCandidateTests.swift"
    ],
    "source-policy": [
      "Tests/RielaCoreTests/SourceDeletionReadinessTests.swift"
    ],
    "telemetry": [
      "Tests/RielaCoreTests/SourceDeletionReadinessTests.swift"
    ],
    "workflow-runtime": [
      "Tests/RielaCoreTests/DeterministicWorkflowRunnerTests.swift",
      "Tests/RielaCoreTests/WorkflowBranchEvaluationTests.swift",
      "Tests/RielaCoreTests/WorkflowModelTests.swift",
      "Tests/RielaCoreTests/WorkflowSessionEntryValidationTests.swift",
      "Tests/RielaCoreTests/RuntimePublicationTests.swift",
      "Tests/RielaCLITests/WorkflowCommandTests.swift"
    ]
  ]

  func testRielaSourceTestSurfaceHasSwiftEquivalentCoverage() throws {
    let sourceTests = Self.sourceTests
    let equivalentSwiftTests = Self.equivalentSwiftTests

    let coverage = Dictionary(grouping: sourceTests, by: sourceTestCategory)
    XCTAssertEqual(sourceTests.count, 147)
    XCTAssertFalse(coverage.keys.contains("unmapped"), coverage["unmapped"]?.joined(separator: "\n") ?? "")
    XCTAssertEqual(Set(coverage.keys), Set(equivalentSwiftTests.keys))
    XCTAssertEqual(coverage["workflow-runtime"]?.count, 58)
    XCTAssertEqual(coverage["events"]?.count, 34)
    XCTAssertEqual(coverage["agent-adapters"]?.count, 11)

    let root = try repositoryRoot()
    for (category, testFiles) in equivalentSwiftTests {
      XCTAssertFalse(testFiles.isEmpty, "missing Swift equivalent tests for \(category)")
      for testFile in testFiles {
        XCTAssertTrue(
          FileManager.default.fileExists(atPath: root.appendingPathComponent(testFile).path),
          "missing Swift equivalent \(testFile) for \(category)"
        )
      }
    }
  }

  func testEnvrcKeepsRielaKinkoDirenvExportValue() throws {
    let root = try repositoryRoot()
    let envrc = try String(contentsOf: root.appendingPathComponent(".envrc"), encoding: .utf8)

    XCTAssertTrue(envrc.contains("# Load secrets from kinko vault."))
    XCTAssertTrue(envrc.contains("# Use direnv-aware export from kinko."))
    XCTAssertTrue(envrc.contains("if command -v kinko >/dev/null 2>&1; then"))
    XCTAssertTrue(envrc.contains(#"eval "$(kinko direnv export)""#))
    XCTAssertTrue(envrc.contains("kinko --force get GEMINI_API_KEY --reveal"))
    XCTAssertTrue(envrc.contains("source_env_if_exists .env.local"))
  }

  private func sourceTestCategory(_ path: String) -> String {
    if path == "packages/riela/src/cli.test.ts" {
      return "cli"
    }
    if path.hasPrefix("packages/riela/src/events/adapters/") {
      return "events-adapters"
    }
    if path.hasPrefix("packages/riela/src/events/") {
      return "events"
    }
    if path.hasPrefix("packages/riela/src/graphql/") {
      return "graphql"
    }
    if path.hasPrefix("packages/riela/src/hook/") {
      return "hook"
    }
    if [
      "packages/riela/src/lib-api.test.ts",
      "packages/riela/src/lib-supervision.test.ts",
      "packages/riela/src/package-boundaries.test.ts"
    ].contains(path) {
      return "library-api"
    }
    if path.hasPrefix("packages/riela/src/server/") {
      return "server"
    }
    if path.hasPrefix("packages/riela/src/shared/") {
      return "shared"
    }
    if path.hasPrefix("packages/riela/src/telemetry/") {
      return "telemetry"
    }
    if path.hasPrefix("packages/riela/src/workflow/adapters/") {
      return "agent-adapters"
    }
    if path.hasPrefix("packages/riela/src/workflow/native-node-executor")
      || path.hasPrefix("packages/riela/src/workflow/node-addons/")
      || path == "packages/riela/src/workflow/addon-package-boundary.test.ts" {
      return "native-addons"
    }
    if path.hasPrefix("packages/riela/src/workflow/packages/")
      || path.hasPrefix("packages/riela/src/workflow/checkout/") {
      return "packages"
    }
    if path.hasPrefix("packages/riela/src/workflow/runtime-db/") {
      return "runtime-db"
    }
    if path.hasPrefix("packages/riela/src/workflow/self-improve/") {
      return "self-improve"
    }
    if path.hasPrefix("packages/riela/src/workflow/") {
      return "workflow-runtime"
    }
    if path.hasPrefix("scripts/") {
      return "source-policy"
    }
    return "unmapped"
  }

  private func repositoryRoot() throws -> URL {
    var url = URL(fileURLWithPath: #filePath)
    while url.pathComponents.count > 1 {
      if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
        return url
      }
      url.deleteLastPathComponent()
    }
    throw NSError(domain: "RielaTestSurfaceCoverageTests", code: 1)
  }
}
