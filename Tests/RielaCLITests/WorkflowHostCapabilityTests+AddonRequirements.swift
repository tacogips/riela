import Foundation
import RielaAddons
import RielaAdapters
import RielaAppSupport
import RielaCore
import RielaWork
import XCTest
@testable import RielaCLI

extension WorkflowHostCapabilityTests {
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

  func testDependencyNativeAddonWithoutInstalledIdentityFailsClosed() async {
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
    XCTAssertEqual(result.exitCode, .failure, result.stdout)
    XCTAssertTrue(result.stdout.contains("unresolvedAddonExecutable"), result.stdout)
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

}
