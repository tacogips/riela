import Foundation
import RielaAdapters
import RielaCore

struct WorkflowStagedVerifier: Sendable {
  func verify(
    target: WorkflowBundleIdentity,
    stagingRoot: URL
  ) throws -> [LoopVerificationEvidence] {
    let staged = try stagedResolutionLayout(target: target, stagingRoot: stagingRoot)
    defer { try? FileManager.default.removeItem(at: staged.root) }
    let workflowDirectory = staged.workflowDirectory
    let bundle = try FileSystemWorkflowBundleResolver(enforcesTransactionBlock: false).resolve(WorkflowResolutionOptions(
      workflowName: target.workflowId,
      scope: .direct,
      workflowDefinitionDir: staged.root.path,
      workingDirectory: staged.root.path
    ))
    let diagnostics = bundle.diagnostics
      + DefaultWorkflowValidator().validate(bundle.workflow, nodePayloads: bundle.nodePayloads)
    let errors = diagnostics.filter { $0.severity == .error }
    guard errors.isEmpty else {
      let summary = errors.map { "\($0.path): \($0.message)" }.joined(separator: "; ")
      throw CLIUsageError("staged workflow validation failed: \(summary)")
    }
    var evidence = [LoopVerificationEvidence(
      id: "workflow-validate",
      outcome: "passed",
      diagnosticSummary: "staged workflow resolved and validated without errors"
    )]
    let required = bundle.workflow.loop?.selfEvolution?.requiredVerification ?? [.workflowValidate]
    if required.contains(.mockScenario) {
      let scenarios = try mockScenarioURLs(in: workflowDirectory)
      guard !scenarios.isEmpty else {
        throw CLIUsageError("staged workflow requires mock-scenario verification but no mock scenario exists")
      }
      for scenarioURL in scenarios {
        let verification = try runMockScenario(bundle: bundle, scenarioURL: scenarioURL)
        let result = verification.result
        guard result.exitCode == 0, result.status == .completed else {
          throw CLIUsageError("staged mock scenario failed: \(scenarioURL.lastPathComponent)")
        }
        try verifyScenarioConsumption(verification.consumedCounts, scenario: verification.scenario)
        evidence.append(LoopVerificationEvidence(
          id: "mock-scenario-\(scenarioURL.deletingPathExtension().lastPathComponent)",
          outcome: "passed",
          diagnosticSummary: "executed \(result.nodeExecutions) node execution(s); status=\(result.status.rawValue)"
        ))
      }
    }
    return evidence
  }

  private func stagedResolutionLayout(
    target: WorkflowBundleIdentity,
    stagingRoot: URL
  ) throws -> (root: URL, workflowDirectory: URL) {
    let parent = stagingRoot.deletingLastPathComponent()
    let root = parent.appendingPathComponent(".riela-verify-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    do {
      let targetDirectory = root.appendingPathComponent(target.workflowId, isDirectory: true)
      try FileManager.default.copyItem(at: stagingRoot, to: targetDirectory)
      let inventory = try WorkflowHistoryIdentityResolver.inventory(for: target, rootOverride: stagingRoot)
      for dependency in inventory.files where WorkflowSharedNodeDependencyInventory.isDependencyPath(
        dependency.metadata.relativePath
      ) {
        let location = try WorkflowSharedNodeDependencyInventory.dependencyLocation(
          for: dependency.metadata.relativePath
        )
        let destination = root
          .appendingPathComponent(location.workflowId, isDirectory: true)
          .appendingPathComponent(location.relativePath)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let reread = try WorkflowDescriptorRelativeReader.read(dependency.url, within: dependency.readRoot)
        guard reread.bytes == dependency.bytes, reread.executable == dependency.metadata.executable else {
          throw CLIUsageError("shared-node dependency changed during staged verification")
        }
        try reread.bytes.write(to: destination, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
          [.posixPermissions: reread.executable ? 0o755 : 0o644],
          ofItemAtPath: destination.path
        )
      }
      let relative = try stagedWorkflowRelativePath(target)
      let workflowDirectory = relative.isEmpty
        ? targetDirectory
        : targetDirectory.appendingPathComponent(relative, isDirectory: true)
      return (root, workflowDirectory)
    } catch {
      try? FileManager.default.removeItem(at: root)
      throw error
    }
  }

  private func stagedWorkflowRelativePath(_ target: WorkflowBundleIdentity) throws -> String {
    let ownershipRoot = URL(fileURLWithPath: target.ownershipRoot, isDirectory: true)
    let workflowDirectory = URL(fileURLWithPath: target.workflowDirectory, isDirectory: true)
    guard WorkflowHistoryIdentityResolver.contained(workflowDirectory, in: ownershipRoot) else {
      throw CLIUsageError("workflow directory is outside the pinned ownership root")
    }
    return String(workflowDirectory.path.dropFirst(ownershipRoot.path.count))
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }

  private func mockScenarioURLs(in workflowDirectory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: workflowDirectory, includingPropertiesForKeys: [.isRegularFileKey])
      .filter { $0.lastPathComponent.hasPrefix("mock-scenario") && $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent.utf8.lexicographicallyPrecedes($1.lastPathComponent.utf8) }
  }

  private func runMockScenario(
    bundle: ResolvedWorkflowBundle,
    scenarioURL: URL
  ) throws -> StagedScenarioVerificationResult {
    let scenario = try WorkflowMockScenarioLoader().loadScenario(at: scenarioURL.path)
    let result = AsyncVerificationResult()
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
      do {
        let adapter = ScenarioNodeAdapter(scenario: scenario, requiresScenarioResponse: true)
        let stdio = ScenarioWorkflowStdioNodeExecutor(
          scenario: scenario,
          fallback: LocalWorkflowStdioNodeExecutor(),
          requiresScenarioResponse: true
        )
        let addon = ScenarioWorkflowAddonResolver(
          scenario: scenario,
          fallback: BuiltinWorkflowAddonResolver(),
          requiresScenarioResponse: true
        )
        let runner = DeterministicWorkflowRunner(
          adapter: adapter,
          addonResolver: addon,
          stdioNodeExecutor: stdio,
          simulatesCrossWorkflowDispatch: true
        )
        let output = try await runner.run(DeterministicWorkflowRunRequest(
          workflow: bundle.workflow,
          nodePayloads: bundle.nodePayloads
        ))
        let adapterCounts = await adapter.consumedResponseCounts()
        let stdioCounts = await stdio.consumedResponseCounts()
        let addonCounts = await addon.consumedResponseCounts()
        let counts = mergeScenarioCounts(adapterCounts, stdioCounts, addonCounts)
        result.store(.success(StagedScenarioVerificationResult(
          result: output,
          scenario: scenario,
          consumedCounts: counts
        )))
      } catch {
        result.store(.failure(error))
      }
      semaphore.signal()
    }
    semaphore.wait()
    return try result.load().get()
  }

  private func verifyScenarioConsumption(
    _ consumed: [String: Int],
    scenario: WorkflowMockScenario
  ) throws {
    let incomplete = scenario.responses.keys.sorted().compactMap { nodeId -> String? in
      let expected = scenario.responses[nodeId]?.count ?? 0
      let actual = consumed[nodeId] ?? 0
      return actual < expected ? "\(nodeId):\(actual)/\(expected)" : nil
    }
    guard incomplete.isEmpty else {
      throw CLIUsageError("staged mock scenario has unconsumed required responses: \(incomplete.joined(separator: ", "))")
    }
  }
}

private final class AsyncVerificationResult: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Result<StagedScenarioVerificationResult, Error>?

  func store(_ value: Result<StagedScenarioVerificationResult, Error>) {
    lock.lock()
    self.value = value
    lock.unlock()
  }

  func load() -> Result<StagedScenarioVerificationResult, Error> {
    lock.lock()
    defer { lock.unlock() }
    return value ?? .failure(CLIUsageError("staged mock scenario did not produce a result"))
  }
}

private struct StagedScenarioVerificationResult: Sendable {
  var result: WorkflowRunResult
  var scenario: WorkflowMockScenario
  var consumedCounts: [String: Int]
}

private func mergeScenarioCounts(_ counts: [String: Int]...) -> [String: Int] {
  var merged: [String: Int] = [:]
  for count in counts {
    for (nodeId, value) in count {
      merged[nodeId, default: 0] += value
    }
  }
  return merged
}
