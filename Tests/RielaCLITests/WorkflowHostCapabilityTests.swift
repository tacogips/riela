import Foundation
import RielaAddons
import RielaAdapters
import RielaAppSupport
import RielaCore
import RielaWork
import XCTest
@testable import RielaCLI

private struct HostValidationBundleResolver: WorkflowBundleResolving {
  var bundle: ResolvedWorkflowBundle
  var bundles: [String: ResolvedWorkflowBundle] = [:]

  func resolve(_ options: WorkflowResolutionOptions) throws -> ResolvedWorkflowBundle {
    bundles[options.workflowName] ?? bundle
  }
}

private struct HostValidationCapabilityResolver: HostCapabilityResolving {
  var snapshots: [HostCapabilitySnapshot]

  init(snapshot: HostCapabilitySnapshot) {
    snapshots = [snapshot]
  }

  init(snapshots: [HostCapabilitySnapshot]) {
    self.snapshots = snapshots
  }

  func resolve(
    host: String,
    scope: WorkflowScope,
    workingDirectory: String,
    readOnly: Bool,
    localAddonExecutables: [String: Bool]
  ) async throws -> [HostCapabilitySnapshot] {
    guard host == "local" else { return snapshots }
    return snapshots.map { snapshot in
      var snapshot = snapshot
      snapshot.addonExecutables.merge(localAddonExecutables) { _, discovered in discovered }
      return snapshot
    }
  }
}

private struct UnsupportedHostCapabilityResolver: HostCapabilityResolving {
  func resolve(
    host: String,
    scope: WorkflowScope,
    workingDirectory: String,
    readOnly: Bool,
    localAddonExecutables: [String: Bool]
  ) async throws -> [HostCapabilitySnapshot] {
    throw HostCapabilityResolverError.unsupportedHost(host)
  }
}

final class WorkflowHostCapabilityTests: XCTestCase {
  func testGeminiPlacementAcceptsEitherProbedCredentialName() async {
    let now = Date(timeIntervalSinceReferenceDate: 1_000)
    let environment = ["GEMINI_API_KEY": "present"]
    let capability = await BackendCapabilityProbe().probe(
      .officialGeminiSDK,
      environment: environment,
      now: now
    )
    let requirement = WorkflowBackendRequirement(
      pin: .officialGeminiSDK,
      provenance: [.init(workflowId: "flow", stepId: "step", nodeId: "node")]
    )
    let host = HostCapabilitySnapshot(
      hostId: "local",
      backends: [capability],
      environment: environment.mapValues { !$0.isEmpty },
      refreshedAt: now
    )

    let result = BackendCapabilityPlacementResolver().resolve(
      requirements: [requirement],
      local: host,
      workers: [],
      now: now
    )

    XCTAssertTrue(result.complete)
    XCTAssertEqual(result.choices.first?.backend, .officialGeminiSDK)
    XCTAssertEqual(capability.requiredEnvironment["GOOGLE_API_KEY"], false)
    XCTAssertEqual(capability.requiredEnvironment["GEMINI_API_KEY"], true)
  }

  func testStrictHostResolvesReachableCalledWorkflowRequirements() async {
    let root = WorkflowDefinition(
      workflowId: "root",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
      entryStepId: "call",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "root-node", nodeFile: "node.json")],
      steps: [WorkflowStepRef(
        id: "call",
        nodeId: "root-node",
        transitions: [WorkflowStepTransition(toStepId: "child-run", toWorkflowId: "child")]
      )],
      nodes: [WorkflowNodeRef(id: "root-node", nodeFile: "node.json")]
    )
    let child = WorkflowDefinition(
      workflowId: "child",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
      entryStepId: "child-run",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "child-node", nodeFile: "node.json")],
      steps: [WorkflowStepRef(id: "child-run", nodeId: "child-node")],
      nodes: [WorkflowNodeRef(id: "child-node", nodeFile: "node.json")]
    )
    let rootBundle = ResolvedWorkflowBundle(
      workflow: root,
      nodePayloads: ["root-node": AgentNodePayload(
        id: "root-node", executionBackend: .codexAgent, model: "gpt", agentSandbox: .readOnly
      )],
      sourceScope: .project,
      workflowDirectory: "/tmp/root"
    )
    let childBundle = ResolvedWorkflowBundle(
      workflow: child,
      nodePayloads: ["child-node": AgentNodePayload(
        id: "child-node", executionBackend: .officialAnthropicSDK, model: "gpt", agentSandbox: .readOnly
      )],
      sourceScope: .project,
      workflowDirectory: "/tmp/child"
    )
    let snapshot = HostCapabilitySnapshot(
      hostId: "local",
      backends: [BackendCapability(
        backend: .codexAgent,
        source: .observed,
        observedAt: Date(),
        availability: .available,
        authentication: .available
      ), BackendCapability(
        backend: .officialAnthropicSDK,
        source: .observed,
        observedAt: Date(),
        availability: .available,
        authentication: .available
      )],
      refreshedAt: Date()
    )
    let command = WorkflowValidateCommand(
      resolver: HostValidationBundleResolver(bundle: rootBundle, bundles: ["child": childBundle]),
      hostResolver: HostValidationCapabilityResolver(snapshot: snapshot)
    )
    let result = await command.run(WorkflowValidateOptions(
      workflowName: root.workflowId,
      resolution: WorkflowResolutionOptions(workflowName: root.workflowId),
      output: .json,
      host: "local",
      strictHost: true
    ))
    XCTAssertEqual(result.exitCode, .failure, result.stdout)
    XCTAssertFalse(result.stdout.contains("host requirements could not be resolved"))
    XCTAssertTrue(result.stdout.contains("official\\/anthropic-sdk"))
  }

  func testHostGapWarnsByDefaultAndFailsStrictWithoutWritingState() async throws {
    let workflow = WorkflowDefinition(
      workflowId: "host-check",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
      entryStepId: "run",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "agent", nodeFile: "node.json")],
      steps: [WorkflowStepRef(id: "run", nodeId: "agent")],
      nodes: [WorkflowNodeRef(id: "agent", nodeFile: "node.json")]
    )
    let bundle = ResolvedWorkflowBundle(
      workflow: workflow,
      nodePayloads: ["agent": AgentNodePayload(
        id: "agent",
        executionBackend: .codexAgent,
        model: "gpt",
        agentSandbox: .readOnly
      )],
      sourceScope: .project,
      workflowDirectory: "/tmp/host-check"
    )
    let snapshot = HostCapabilitySnapshot(
      hostId: "local",
      backends: [BackendCapability(
        backend: .codexAgent,
        source: .observed,
        observedAt: Date(),
        availability: .unavailable
      )],
      refreshedAt: Date()
    )
    let command = WorkflowValidateCommand(
      resolver: HostValidationBundleResolver(bundle: bundle),
      hostResolver: HostValidationCapabilityResolver(snapshot: snapshot)
    )
    let resolution = WorkflowResolutionOptions(workflowName: workflow.workflowId)
    let warning = await command.run(WorkflowValidateOptions(
      workflowName: workflow.workflowId,
      resolution: resolution,
      output: .json,
      host: "local"
    ))
    XCTAssertEqual(warning.exitCode, .success)
    XCTAssertTrue(warning.stdout.contains(#""severity":"warning""#))
    XCTAssertTrue(warning.stdout.contains("backend-unavailable"))

    let strict = await command.run(WorkflowValidateOptions(
      workflowName: workflow.workflowId,
      resolution: resolution,
      output: .json,
      host: "local",
      strictHost: true
    ))
    XCTAssertEqual(strict.exitCode, .failure)
    XCTAssertTrue(strict.stdout.contains(#""severity":"error""#))
  }

  func testStrictHostRequiresHostDuringParsing() {
    for command in ["validate", "inspect", "usage"] {
      XCTAssertThrowsError(try RielaArgumentParser().parse([
        "workflow", command, "host-check", "--strict-host"
      ])) { error in
        XCTAssertTrue(String(describing: error).contains("requires --host"))
      }
    }
  }

  func testInspectAndUsageParseHostOptionsEquivalently() throws {
    let parser = RielaArgumentParser()
    let inspect = try parser.parse([
      "workflow", "inspect", "host-check", "--host", "builders", "--strict-host"
    ])
    let usage = try parser.parse([
      "workflow", "usage", "host-check", "--host", "builders", "--strict-host"
    ])
    guard case let .workflow(.inspect(inspectOptions)) = inspect,
          case let .workflow(.usage(usageOptions)) = usage else {
      return XCTFail("expected inspect and usage commands")
    }
    XCTAssertEqual(inspectOptions, usageOptions)
    XCTAssertEqual(inspectOptions.host, "builders")
    XCTAssertTrue(inspectOptions.strictHost)
  }

  func testInspectHostProjectionIncludesRootAndReachableCalleeForLocalAndWorker() async throws {
    let fixtures = rootAndChildBundles()
    let now = Date()
    let snapshot = HostCapabilitySnapshot(
      hostId: "worker-a",
      groups: ["builders"],
      capacity: 2,
      backends: [
        availableCapability(.codexAgent, models: ["gpt"], now: now),
        availableCapability(.officialAnthropicSDK, models: ["claude"], now: now)
      ],
      refreshedAt: now
    )
    let command = WorkflowInspectCommand(
      resolver: HostValidationBundleResolver(bundle: fixtures.root, bundles: ["child": fixtures.child]),
      hostResolver: HostValidationCapabilityResolver(snapshot: snapshot)
    )

    for host in ["local", "builders"] {
      let result = await command.run(WorkflowInspectOptions(
        workflowName: "root",
        resolution: WorkflowResolutionOptions(workflowName: "root"),
        output: .json,
        host: host
      ))
      XCTAssertEqual(result.exitCode, .failure, result.stdout)
      let summary = try JSONDecoder().decode(
        WorkflowInspectionSummary.self,
        from: Data(result.stdout.utf8)
      )
      XCTAssertEqual(summary.backendRequirements.count, 2)
      XCTAssertEqual(
        Set(summary.backendRequirements.flatMap(\.provenance).map { "\($0.workflowId):\($0.stepId)" }),
        ["root:call", "child:child-run"]
      )
      XCTAssertFalse(summary.runtimeCapabilityGaps.contains {
        $0.path == "workflow.host" || $0.message.hasPrefix("host ")
      })
    }

    let single = singleAgentWorkflow()
    let singleBundle = ResolvedWorkflowBundle(
      workflow: single,
      nodePayloads: ["agent": AgentNodePayload(
        id: "agent", executionBackend: .codexAgent, model: "gpt", agentSandbox: .readOnly
      )],
      sourceScope: .project,
      workflowDirectory: "/tmp/inspect-host-check"
    )
    let strictCommand = WorkflowInspectCommand(
      resolver: HostValidationBundleResolver(bundle: singleBundle),
      hostResolver: HostValidationCapabilityResolver(snapshot: snapshot)
    )
    for host in ["local", "builders"] {
      let result = await strictCommand.run(inspectOptions(host: host, strict: true))
      XCTAssertEqual(result.exitCode, .success, result.stdout)
    }
  }

  func testInspectHostBackendAndEnvironmentGapsWarnThenFailStrict() async {
    let workflow = singleAgentWorkflow()
    let bundle = ResolvedWorkflowBundle(
      workflow: workflow,
      nodePayloads: ["agent": AgentNodePayload(
        id: "agent", executionBackend: .codexAgent, model: "gpt", agentSandbox: .readOnly,
        agentEnvironment: [
          "WORKFLOW_REQUIRED_TOKEN": AgentEnvironmentBinding(fromEnv: "REQUIRED_TOKEN", required: true)
        ]
      )],
      sourceScope: .project,
      workflowDirectory: "/tmp/inspect-host-check"
    )
    let now = Date()
    let fixtures: [HostCapabilitySnapshot] = [
      HostCapabilitySnapshot(
        hostId: "unavailable",
        backends: [BackendCapability(
          backend: .codexAgent, source: .observed, observedAt: now,
          availability: .unavailable
        )],
        environment: ["REQUIRED_TOKEN": true],
        refreshedAt: now
      ),
      HostCapabilitySnapshot(
        hostId: "stale",
        backends: [availableCapability(
          .codexAgent, models: ["gpt"], now: now.addingTimeInterval(-301)
        )],
        environment: ["REQUIRED_TOKEN": true],
        refreshedAt: now
      ),
      HostCapabilitySnapshot(
        hostId: "missing-env",
        backends: [availableCapability(.codexAgent, models: ["gpt"], now: now)],
        environment: [:],
        refreshedAt: now
      )
    ]
    for snapshot in fixtures {
      let command = WorkflowInspectCommand(
        resolver: HostValidationBundleResolver(bundle: bundle),
        hostResolver: HostValidationCapabilityResolver(snapshot: snapshot)
      )
      let warning = await command.run(inspectOptions(host: snapshot.hostId))
      XCTAssertEqual(warning.exitCode, .success, warning.stdout)
      XCTAssertTrue(warning.stdout.contains(#""severity":"warning""#), warning.stdout)
      XCTAssertTrue(warning.stdout.contains("backend-unavailable"), warning.stdout)

      let strict = await command.run(inspectOptions(host: snapshot.hostId, strict: true))
      XCTAssertEqual(strict.exitCode, .failure, strict.stdout)
      XCTAssertTrue(strict.stdout.contains(#""severity":"error""#), strict.stdout)
    }
  }

  func testInspectAddonGapWarnsThenFailsStrict() async {
    let bundle = localCommandAddonBundle()
    let command = WorkflowInspectCommand(
      resolver: HostValidationBundleResolver(bundle: bundle),
      hostResolver: HostValidationCapabilityResolver(snapshot: HostCapabilitySnapshot(
        hostId: "local", backends: [], refreshedAt: Date()
      ))
    )
    let warning = await command.run(inspectOptions(host: "local"))
    XCTAssertEqual(warning.exitCode, .success, warning.stdout)
    XCTAssertTrue(warning.stdout.contains("addon-executable-unavailable: tool-cli"), warning.stdout)
    XCTAssertTrue(warning.stdout.contains(#""severity":"warning""#), warning.stdout)

    let strict = await command.run(inspectOptions(host: "local", strict: true))
    XCTAssertEqual(strict.exitCode, .failure, strict.stdout)
    XCTAssertTrue(strict.stdout.contains(#""severity":"error""#), strict.stdout)
  }

  func testInspectProjectionFailureIsVisibleAndUsageAliasIsEquivalent() async throws {
    let workflow = WorkflowDefinition(
      workflowId: "unresolved-addon",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
      entryStepId: "run",
      nodeRegistry: [WorkflowNodeRegistryRef(
        id: "tool", addon: WorkflowNodeAddonRef(name: "missing/tool", version: "1")
      )],
      steps: [WorkflowStepRef(id: "run", nodeId: "tool")],
      nodes: []
    )
    let bundle = ResolvedWorkflowBundle(
      workflow: workflow,
      nodePayloads: [:],
      sourceScope: .project,
      workflowDirectory: "/tmp/unresolved-addon"
    )
    let command = WorkflowInspectCommand(
      resolver: HostValidationBundleResolver(bundle: bundle),
      hostResolver: HostValidationCapabilityResolver(snapshot: HostCapabilitySnapshot(
        hostId: "local", backends: [], refreshedAt: Date()
      ))
    )
    let app = RielaCLIApplication(inspectCommand: command)
    let base = [
      "unresolved-addon", "--workflow-definition-dir", "/tmp/unresolved-addon", "--output", "json"
    ]
    for hostOptions in [[], ["--host", "local"]] {
      let inspect = await app.run(["workflow", "inspect"] + base + hostOptions)
      let usage = await app.run(["workflow", "usage"] + base + hostOptions)
      XCTAssertEqual(inspect.exitCode, .failure, inspect.stdout)
      XCTAssertEqual(usage, inspect)
      XCTAssertTrue(inspect.stdout.contains("host requirements could not be resolved"), inspect.stdout)
      XCTAssertTrue(inspect.stdout.contains("unresolvedAddonExecutable"), inspect.stdout)
      XCTAssertTrue(inspect.stdout.contains(#""severity":"error""#), inspect.stdout)
    }

    let validate = WorkflowValidateCommand(
      resolver: HostValidationBundleResolver(bundle: bundle),
      hostResolver: HostValidationCapabilityResolver(snapshot: HostCapabilitySnapshot(
        hostId: "local", backends: [], refreshedAt: Date()
      ))
    )
    for host in [nil, "local"] as [String?] {
      let result = await validate.run(WorkflowValidateOptions(
        workflowName: workflow.workflowId,
        resolution: WorkflowResolutionOptions(workflowName: workflow.workflowId),
        output: .json,
        host: host
      ))
      XCTAssertEqual(result.exitCode, .failure, result.stdout)
      XCTAssertTrue(result.stdout.contains("unresolvedAddonExecutable"), result.stdout)
      XCTAssertTrue(result.stdout.contains(#""severity":"error""#), result.stdout)
    }
  }

  func testUnreachableMissingCalleeDoesNotAffectRequirementProjection() async {
    let workflow = WorkflowDefinition(
      workflowId: "reachable-only",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
      entryStepId: "run",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "agent", nodeFile: "node.json")],
      steps: [
        WorkflowStepRef(id: "run", nodeId: "agent"),
        WorkflowStepRef(
          id: "unused", nodeId: "agent",
          transitions: [WorkflowStepTransition(toStepId: "run", toWorkflowId: "missing")]
        )
      ],
      nodes: [WorkflowNodeRef(id: "agent", nodeFile: "node.json")]
    )
    let bundle = ResolvedWorkflowBundle(
      workflow: workflow,
      nodePayloads: ["agent": AgentNodePayload(
        id: "agent", executionBackend: .codexAgent, model: "gpt", agentSandbox: .readOnly
      )],
      sourceScope: .project,
      workflowDirectory: "/tmp/reachable-only"
    )
    let command = WorkflowInspectCommand(
      resolver: HostValidationBundleResolver(bundle: bundle),
      hostResolver: HostValidationCapabilityResolver(snapshots: [])
    )
    let result = await command.run(WorkflowInspectOptions(
      workflowName: workflow.workflowId,
      resolution: WorkflowResolutionOptions(workflowName: workflow.workflowId),
      output: .json
    ))
    XCTAssertEqual(result.exitCode, .success, result.stdout)
    XCTAssertFalse(result.stdout.contains("host requirements could not be resolved"), result.stdout)
  }

  func testBuiltInAndDeclarativeAddonsNeedNoHostExecutable() async {
    for (addonName, manifest) in [
      ("riela/kv-get", Optional<WorkflowPackageManifest>.none),
      ("example/declarative", WorkflowPackageManifest(
        name: "example-package",
        nodeAddons: [WorkflowPackageNodeAddon(
          name: "example/declarative",
          version: "1",
          sourcePath: "addons/declarative",
          execution: WorkflowPackageAddonExecutionDescriptor(kind: .declarative)
        )]
      ))
    ] {
      let workflow = WorkflowDefinition(
        workflowId: "host-neutral-addon",
        defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
        entryStepId: "run",
        nodeRegistry: [WorkflowNodeRegistryRef(
          id: "tool", addon: WorkflowNodeAddonRef(name: addonName, version: "1")
        )],
        steps: [WorkflowStepRef(id: "run", nodeId: "tool")],
        nodes: []
      )
      let bundle = ResolvedWorkflowBundle(
        workflow: workflow,
        nodePayloads: [:],
        sourceScope: .project,
        workflowDirectory: "/tmp/host-neutral-addon",
        packageManifest: manifest
      )
      let command = WorkflowInspectCommand(
        resolver: HostValidationBundleResolver(bundle: bundle),
        hostResolver: HostValidationCapabilityResolver(snapshots: [])
      )
      let result = await command.run(WorkflowInspectOptions(
        workflowName: workflow.workflowId,
        resolution: WorkflowResolutionOptions(workflowName: workflow.workflowId),
        output: .json
      ))
      XCTAssertEqual(result.exitCode, .success, result.stdout)
      XCTAssertFalse(result.stdout.contains("unresolvedAddonExecutable"), result.stdout)
    }
  }

  func testDependencyNativeAddonRemainsInspectableWithoutHostExecutable() async {
    let workflow = WorkflowDefinition(
      workflowId: "dependency-native-addon",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
      entryStepId: "run",
      nodeRegistry: [WorkflowNodeRegistryRef(
        id: "tool", addon: WorkflowNodeAddonRef(name: "native-package/native-runner", version: "1")
      )],
      steps: [WorkflowStepRef(id: "run", nodeId: "tool")],
      nodes: []
    )
    let bundle = ResolvedWorkflowBundle(
      workflow: workflow, nodePayloads: [:], sourceScope: .project,
      workflowDirectory: "/tmp/dependency-native-addon",
      packageManifest: WorkflowPackageManifest(
        name: "native-workflow",
        dependencies: [WorkflowPackageDependency(
          packageId: "native-package", kind: .nodeAddon,
          addons: [WorkflowPackageManifestAddonDependencyLock(
            name: "native-runner", version: "1", executionKind: .nativeBundle
          )]
        )]
      )
    )
    let command = WorkflowInspectCommand(
      resolver: HostValidationBundleResolver(bundle: bundle),
      hostResolver: HostValidationCapabilityResolver(snapshots: [])
    )
    let result = await command.run(WorkflowInspectOptions(
      workflowName: workflow.workflowId,
      resolution: WorkflowResolutionOptions(workflowName: workflow.workflowId),
      output: .json
    ))
    XCTAssertEqual(result.exitCode, .success, result.stdout)
    XCTAssertFalse(result.stdout.contains("unresolvedAddonExecutable"), result.stdout)
  }

  func testRequiredAddonEnvironmentBindingsReachStrictHostValidation() async {
    let workflow = WorkflowDefinition(
      workflowId: "addon-env-check",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
      entryStepId: "run",
      nodeRegistry: [WorkflowNodeRegistryRef(
        id: "tool", addon: WorkflowNodeAddonRef(
          name: "riela/kv-get", version: "1",
          env: [
            "TOKEN": .object(["fromEnv": .string("CUSTOM_KEY")]),
            "EXPLICIT": .object(["fromEnv": .string("EXPLICIT_KEY"), "required": .bool(true)]),
            "OPTIONAL": .object(["fromEnv": .string("OPTIONAL_KEY"), "required": .bool(false)])
          ]
        )
      )],
      steps: [WorkflowStepRef(id: "run", nodeId: "tool")], nodes: []
    )
    let bundle = ResolvedWorkflowBundle(
      workflow: workflow, nodePayloads: [:], sourceScope: .project,
      workflowDirectory: "/tmp/addon-env-check"
    )
    let resolver = HostValidationBundleResolver(bundle: bundle)
    let inspect = await WorkflowInspectCommand(
      resolver: resolver,
      hostResolver: HostValidationCapabilityResolver(snapshots: [])
    ).run(WorkflowInspectOptions(
      workflowName: workflow.workflowId,
      resolution: WorkflowResolutionOptions(workflowName: workflow.workflowId),
      output: .json
    ))
    XCTAssertEqual(inspect.exitCode, .success, inspect.stdout)
    XCTAssertTrue(inspect.stdout.contains("CUSTOM_KEY"), inspect.stdout)
    XCTAssertTrue(inspect.stdout.contains("EXPLICIT_KEY"), inspect.stdout)
    XCTAssertFalse(inspect.stdout.contains("OPTIONAL_KEY"), inspect.stdout)
    let command = WorkflowValidateCommand(
      resolver: resolver,
      hostResolver: HostValidationCapabilityResolver(snapshot: HostCapabilitySnapshot(
        hostId: "local", backends: [], environment: [:], refreshedAt: Date()
      ))
    )
    let result = await command.run(WorkflowValidateOptions(
      workflowName: workflow.workflowId,
      resolution: WorkflowResolutionOptions(workflowName: workflow.workflowId),
      output: .json, host: "local", strictHost: true
    ))
    XCTAssertEqual(result.exitCode, .failure, result.stdout)
    let present = await WorkflowValidateCommand(
      resolver: resolver,
      hostResolver: HostValidationCapabilityResolver(snapshot: HostCapabilitySnapshot(
        hostId: "local", backends: [],
        environment: ["CUSTOM_KEY": true, "EXPLICIT_KEY": true], refreshedAt: Date()
      ))
    ).run(WorkflowValidateOptions(
      workflowName: workflow.workflowId,
      resolution: WorkflowResolutionOptions(workflowName: workflow.workflowId),
      output: .json, host: "local", strictHost: true
    ))
    XCTAssertEqual(present.exitCode, .success, present.stdout)
  }

  func testInspectAndUsagePreserveRequirementsWhenHostResolutionFails() async throws {
    let workflow = singleAgentWorkflow()
    let bundle = ResolvedWorkflowBundle(
      workflow: workflow,
      nodePayloads: ["agent": AgentNodePayload(
        id: "agent", executionBackend: .codexAgent, model: "gpt", agentSandbox: .readOnly
      )],
      sourceScope: .project,
      workflowDirectory: "/tmp/inspect-host-check"
    )
    let app = RielaCLIApplication(inspectCommand: WorkflowInspectCommand(
      resolver: HostValidationBundleResolver(bundle: bundle),
      hostResolver: UnsupportedHostCapabilityResolver()
    ))
    let base = [
      "inspect-host-check", "--workflow-definition-dir", "/tmp/inspect-host-check",
      "--host", "missing-worker", "--output", "json"
    ]

    let warningInspect = await app.run(["workflow", "inspect"] + base)
    let warningUsage = await app.run(["workflow", "usage"] + base)
    XCTAssertEqual(warningInspect.exitCode, .success, warningInspect.stdout)
    XCTAssertEqual(warningUsage, warningInspect)
    let warningSummary = try JSONDecoder().decode(
      WorkflowInspectionSummary.self,
      from: Data(warningInspect.stdout.utf8)
    )
    XCTAssertEqual(warningSummary.backendRequirements.count, 1)
    XCTAssertEqual(warningSummary.runtimeCapabilityGaps.last?.severity, .warning)
    XCTAssertTrue(warningSummary.runtimeCapabilityGaps.last?.message.contains("unsupportedHost") == true)

    let strictInspect = await app.run(["workflow", "inspect"] + base + ["--strict-host"])
    let strictUsage = await app.run(["workflow", "usage"] + base + ["--strict-host"])
    XCTAssertEqual(strictInspect.exitCode, .failure, strictInspect.stdout)
    XCTAssertEqual(strictUsage, strictInspect)
    let strictSummary = try JSONDecoder().decode(
      WorkflowInspectionSummary.self,
      from: Data(strictInspect.stdout.utf8)
    )
    XCTAssertEqual(strictSummary.backendRequirements.count, 1)
    XCTAssertEqual(strictSummary.runtimeCapabilityGaps.last?.severity, .error)
  }

  func testGroupValidationAcceptsACompleteCandidateInsteadOfMixingHosts() async {
    let workflow = WorkflowDefinition(
      workflowId: "group-check",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
      entryStepId: "run",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "agent", nodeFile: "node.json")],
      steps: [WorkflowStepRef(id: "run", nodeId: "agent")],
      nodes: [WorkflowNodeRef(id: "agent", nodeFile: "node.json")]
    )
    let bundle = ResolvedWorkflowBundle(
      workflow: workflow,
      nodePayloads: ["agent": AgentNodePayload(
        id: "agent",
        executionBackend: .codexAgent,
        model: "gpt",
        agentSandbox: .readOnly
      )],
      sourceScope: .project,
      workflowDirectory: "/tmp/group-check"
    )
    let now = Date()
    func snapshot(_ id: String, availability: BackendCapability.Availability) -> HostCapabilitySnapshot {
      HostCapabilitySnapshot(
        hostId: id,
        groups: ["builders"],
        capacity: 1,
        backends: [.init(
          backend: .codexAgent,
          source: .observed,
          observedAt: now,
          availability: availability,
          authentication: .available,
          models: ["gpt"]
        )],
        refreshedAt: now
      )
    }
    let command = WorkflowValidateCommand(
      resolver: HostValidationBundleResolver(bundle: bundle),
      hostResolver: HostValidationCapabilityResolver(snapshots: [
        snapshot("worker-a", availability: .unavailable),
        snapshot("worker-b", availability: .available)
      ])
    )
    let result = await command.run(WorkflowValidateOptions(
      workflowName: workflow.workflowId,
      resolution: WorkflowResolutionOptions(workflowName: workflow.workflowId),
      output: .json,
      host: "builders",
      strictHost: true
    ))
    XCTAssertEqual(result.exitCode, .success)
    XCTAssertFalse(result.stdout.contains("backend-unavailable"))
  }

}

extension WorkflowHostCapabilityTests {
  func testGroupValidationPlacesReachableStepsAcrossLiveWorkers() async {
    let workflow = WorkflowDefinition(
      workflowId: "group-split",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
      entryStepId: "first",
      nodeRegistry: [
        WorkflowNodeRegistryRef(id: "first-node", nodeFile: "first.json"),
        WorkflowNodeRegistryRef(id: "second-node", nodeFile: "second.json")
      ],
      steps: [
        WorkflowStepRef(id: "first", nodeId: "first-node", transitions: [
          WorkflowStepTransition(toStepId: "second")
        ]),
        WorkflowStepRef(id: "second", nodeId: "second-node")
      ],
      nodes: [
        WorkflowNodeRef(id: "first-node", nodeFile: "first.json"),
        WorkflowNodeRef(id: "second-node", nodeFile: "second.json")
      ]
    )
    let bundle = ResolvedWorkflowBundle(
      workflow: workflow,
      nodePayloads: [
        "first-node": AgentNodePayload(
          id: "first-node", executionBackend: .codexAgent, model: "test-model", agentSandbox: .readOnly
        ),
        "second-node": AgentNodePayload(
          id: "second-node", executionBackend: .claudeCodeAgent, model: "test-model", agentSandbox: .readOnly
        )
      ],
      sourceScope: .project,
      workflowDirectory: "/tmp/group-split"
    )
    let now = Date()
    func snapshot(_ id: String, backend: NodeExecutionBackend) -> HostCapabilitySnapshot {
      HostCapabilitySnapshot(
        hostId: id, groups: ["builders"], capacity: 1,
        backends: [.init(
          backend: backend, source: .observed, observedAt: now,
          availability: .available, authentication: .available, models: ["test-model"]
        )],
        refreshedAt: now
      )
    }
    let command = WorkflowValidateCommand(
      resolver: HostValidationBundleResolver(bundle: bundle),
      hostResolver: HostValidationCapabilityResolver(snapshots: [
        snapshot("worker-a", backend: .codexAgent),
        snapshot("worker-b", backend: .claudeCodeAgent)
      ])
    )
    let result = await command.run(WorkflowValidateOptions(
      workflowName: workflow.workflowId,
      resolution: WorkflowResolutionOptions(workflowName: workflow.workflowId),
      output: .json,
      host: "builders",
      strictHost: true
    ))
    XCTAssertEqual(result.exitCode, .success, result.stdout)

    var assignedBundle = bundle
    assignedBundle.workflow.steps[0].placement = DistributedExecutionPlacement(
      target: DistributedWorkerTarget(workerId: "worker-b"), workspace: "/tmp"
    )
    let assigned = WorkflowValidateCommand(
      resolver: HostValidationBundleResolver(bundle: assignedBundle),
      hostResolver: HostValidationCapabilityResolver(snapshots: [
        snapshot("worker-a", backend: .codexAgent),
        snapshot("worker-b", backend: .claudeCodeAgent)
      ])
    )
    let rejected = await assigned.run(WorkflowValidateOptions(
      workflowName: workflow.workflowId,
      resolution: WorkflowResolutionOptions(workflowName: workflow.workflowId),
      output: .json, host: "builders", strictHost: true
    ))
    XCTAssertEqual(rejected.exitCode, .failure)
  }

  func testDefaultResolverReadsFreshRegisteredWorkerAndRejectsStaleSnapshot() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let environment = ["RIELA_SESSION_STORE": root.path]
    let store = WorkStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root.path))
    let fresh = HostCapabilitySnapshot(
      hostId: "worker-a",
      groups: ["builders"],
      capacity: 1,
      backends: [],
      refreshedAt: Date()
    )
    try store.saveHostSnapshot(fresh)
    let beforeRead = try Data(contentsOf: URL(fileURLWithPath: store.databasePath))
    let sidecars = ["-wal", "-shm"].map {
      FileManager.default.fileExists(atPath: store.databasePath + $0)
    }
    let resolver = HostCapabilityResolver(environment: environment)
    let resolved = try await resolver.resolve(
      host: "builders", scope: .project, workingDirectory: root.path, readOnly: true
    )
    XCTAssertEqual(resolved.map(\.hostId), ["worker-a"])
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: store.databasePath)), beforeRead)
    XCTAssertEqual(["-wal", "-shm"].map {
      FileManager.default.fileExists(atPath: store.databasePath + $0)
    }, sidecars)

    var stale = fresh
    stale.refreshedAt = Date().addingTimeInterval(-31)
    try store.saveHostSnapshot(stale)
    do {
      _ = try await resolver.resolve(
        host: "worker-a", scope: .project, workingDirectory: root.path, readOnly: true
      )
      XCTFail("Stale registration was treated as live")
    } catch {
      XCTAssertEqual(error as? HostCapabilityResolverError, .unsupportedHost("worker-a"))
    }

    var future = fresh
    future.refreshedAt = Date().addingTimeInterval(31)
    try store.saveHostSnapshot(future)
    do {
      _ = try await resolver.resolve(
        host: "worker-a", scope: .project, workingDirectory: root.path, readOnly: true
      )
      XCTFail("Future-dated registration was treated as live")
    } catch {
      XCTAssertEqual(error as? HostCapabilityResolverError, .unsupportedHost("worker-a"))
    }
  }

  func testDefaultLocalResolverUsesSelectedProfileBackendDeclarations() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let activeStore = RielaAppProfileStore(appRootURL: root)
    let work = RielaAppProfileName("work")
    try activeStore.saveActiveProfileName(work)
    let stateURL = RielaAppProfileStore.profilesRootURL(appRootURL: root)
      .appendingPathComponent(work.rawValue, isDirectory: true)
      .appendingPathComponent("daemon-workflows.json")
    try RielaAppDaemonWorkflowStore(stateURL: stateURL, profileName: work).save(
      RielaAppDaemonWorkflowState(backends: [
        NodeExecutionBackend.officialOpenAISDK.rawValue: BackendCapabilityDeclaration(enabled: true)
      ])
    )

    let resolver = HostCapabilityResolver(activeProfileStore: activeStore, environment: [:])
    let snapshots = try await resolver.resolve(
      host: "local", scope: .project, workingDirectory: root.path, readOnly: true
    )
    XCTAssertEqual(resolver.profileStore.profileName, work)
    XCTAssertEqual(snapshots.first?.capability(for: .officialOpenAISDK)?.availability, .available)
    XCTAssertEqual(snapshots.first?.capability(for: .officialOpenAISDK)?.source, .merged)
  }

  func testManifestLocalCommandAddonProjectsExecutableIntoStrictHostValidation() async {
    let workflow = WorkflowDefinition(
      workflowId: "addon-host-check",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
      entryStepId: "run",
      nodeRegistry: [WorkflowNodeRegistryRef(
        id: "tool",
        addon: WorkflowNodeAddonRef(name: "example/tool", version: "1")
      )],
      steps: [WorkflowStepRef(id: "run", nodeId: "tool")],
      nodes: []
    )
    let bundle = ResolvedWorkflowBundle(
      workflow: workflow,
      nodePayloads: [:],
      sourceScope: .project,
      workflowDirectory: "/tmp/addon-host-check",
      packageManifest: WorkflowPackageManifest(
        name: "example-package",
        nodeAddons: [WorkflowPackageNodeAddon(
          name: "example/tool",
          version: "1",
          sourcePath: "addons/tool",
          execution: WorkflowPackageAddonExecutionDescriptor(
            kind: .localCommand,
            entrypoint: "tool-cli"
          )
        )]
      )
    )
    let snapshot = HostCapabilitySnapshot(hostId: "local", backends: [], refreshedAt: Date())
    let command = WorkflowValidateCommand(
      resolver: HostValidationBundleResolver(bundle: bundle),
      hostResolver: HostValidationCapabilityResolver(snapshot: snapshot)
    )
    let result = await command.run(WorkflowValidateOptions(
      workflowName: workflow.workflowId,
      resolution: WorkflowResolutionOptions(workflowName: workflow.workflowId),
      output: .json,
      host: "local",
      strictHost: true
    ))
    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(result.stdout.contains("addon-executable-unavailable: tool-cli"))
  }

  func testInstalledExecutableLocalCommandAddonPassesStrictHostValidation() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-addon-host-\(UUID().uuidString)", isDirectory: true)
    let addonRoot = root.appendingPathComponent("addons/tool", isDirectory: true)
    try FileManager.default.createDirectory(at: addonRoot, withIntermediateDirectories: true)
    let executable = addonRoot.appendingPathComponent("tool-cli")
    XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data("#!/bin/sh\n".utf8)))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    defer { try? FileManager.default.removeItem(at: root) }

    let workflow = WorkflowDefinition(
      workflowId: "installed-addon-host-check",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
      entryStepId: "run",
      nodeRegistry: [
        WorkflowNodeRegistryRef(id: "tool", addon: WorkflowNodeAddonRef(name: "example/tool", version: "1")),
        WorkflowNodeRegistryRef(id: "unused", addon: WorkflowNodeAddonRef(name: "example/unused", version: "1"))
      ],
      steps: [WorkflowStepRef(id: "run", nodeId: "tool")],
      nodes: []
    )
    let bundle = ResolvedWorkflowBundle(
      workflow: workflow,
      nodePayloads: [:],
      sourceScope: .project,
      workflowDirectory: root.appendingPathComponent("workflow").path,
      packageManifest: WorkflowPackageManifest(
        name: "example-package",
        nodeAddons: [
          WorkflowPackageNodeAddon(
            name: "example/tool",
            version: "1",
            sourcePath: "addons/tool",
            execution: WorkflowPackageAddonExecutionDescriptor(kind: .localCommand, entrypoint: "tool-cli")
          ),
          WorkflowPackageNodeAddon(
            name: "example/unused",
            version: "1",
            sourcePath: "addons/unused",
            execution: WorkflowPackageAddonExecutionDescriptor(kind: .localCommand, entrypoint: "tool-cli")
          )
        ]
      ),
      packageDirectory: root.path
    )
    let snapshot = HostCapabilitySnapshot(hostId: "local", backends: [], refreshedAt: Date())
    let command = WorkflowValidateCommand(
      resolver: HostValidationBundleResolver(bundle: bundle),
      hostResolver: HostValidationCapabilityResolver(snapshot: snapshot)
    )

    let result = await command.run(WorkflowValidateOptions(
      workflowName: workflow.workflowId,
      resolution: WorkflowResolutionOptions(workflowName: workflow.workflowId),
      output: .json,
      host: "local",
      strictHost: true
    ))

    XCTAssertEqual(result.exitCode, .success, result.stdout)
    XCTAssertFalse(result.stdout.contains("addon-executable-unavailable"))
  }

  private func inspectOptions(host: String, strict: Bool = false) -> WorkflowInspectOptions {
    WorkflowInspectOptions(
      workflowName: "inspect-host-check",
      resolution: WorkflowResolutionOptions(workflowName: "inspect-host-check"),
      output: .json,
      host: host,
      strictHost: strict
    )
  }

  private func singleAgentWorkflow() -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "inspect-host-check",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
      entryStepId: "run",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "agent", nodeFile: "node.json")],
      steps: [WorkflowStepRef(id: "run", nodeId: "agent")],
      nodes: [WorkflowNodeRef(id: "agent", nodeFile: "node.json")]
    )
  }

  private func availableCapability(
    _ backend: NodeExecutionBackend,
    models: [String],
    now: Date
  ) -> BackendCapability {
    BackendCapability(
      backend: backend,
      source: .observed,
      observedAt: now,
      availability: .available,
      authentication: .available,
      models: models
    )
  }

  private func rootAndChildBundles() -> (root: ResolvedWorkflowBundle, child: ResolvedWorkflowBundle) {
    let root = WorkflowDefinition(
      workflowId: "root",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
      entryStepId: "call",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "root-node", nodeFile: "node.json")],
      steps: [WorkflowStepRef(
        id: "call", nodeId: "root-node",
        transitions: [WorkflowStepTransition(toStepId: "child-run", toWorkflowId: "child")]
      )],
      nodes: [WorkflowNodeRef(id: "root-node", nodeFile: "node.json")]
    )
    let child = WorkflowDefinition(
      workflowId: "child",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
      entryStepId: "child-run",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "child-node", nodeFile: "node.json")],
      steps: [WorkflowStepRef(id: "child-run", nodeId: "child-node")],
      nodes: [WorkflowNodeRef(id: "child-node", nodeFile: "node.json")]
    )
    return (
      ResolvedWorkflowBundle(
        workflow: root,
        nodePayloads: ["root-node": AgentNodePayload(
          id: "root-node", executionBackend: .codexAgent, model: "gpt", agentSandbox: .readOnly
        )],
        sourceScope: .project,
        workflowDirectory: "/tmp/root"
      ),
      ResolvedWorkflowBundle(
        workflow: child,
        nodePayloads: ["child-node": AgentNodePayload(
          id: "child-node", executionBackend: .officialAnthropicSDK,
          model: "claude", agentSandbox: .readOnly
        )],
        sourceScope: .project,
        workflowDirectory: "/tmp/child"
      )
    )
  }

  private func localCommandAddonBundle() -> ResolvedWorkflowBundle {
    let workflow = WorkflowDefinition(
      workflowId: "inspect-host-check",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
      entryStepId: "run",
      nodeRegistry: [WorkflowNodeRegistryRef(
        id: "tool", addon: WorkflowNodeAddonRef(name: "example/tool", version: "1")
      )],
      steps: [WorkflowStepRef(id: "run", nodeId: "tool")],
      nodes: []
    )
    return ResolvedWorkflowBundle(
      workflow: workflow,
      nodePayloads: [:],
      sourceScope: .project,
      workflowDirectory: "/tmp/addon-host-check",
      packageManifest: WorkflowPackageManifest(
        name: "example-package",
        nodeAddons: [WorkflowPackageNodeAddon(
          name: "example/tool",
          version: "1",
          sourcePath: "addons/tool",
          execution: WorkflowPackageAddonExecutionDescriptor(
            kind: .localCommand,
            entrypoint: "tool-cli"
          )
        )]
      )
    )
  }
}
