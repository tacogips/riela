import Foundation
import RielaCore
import RielaKaibaAddons
import RielaKaibaSupport

struct SessionKaibaPreflightContext: Sendable {
  let workingDirectory: String
  let environment: [String: String]
  let snapshot: KaibaExecutionSnapshot?
}

func prepareSessionKaibaPreflight(
  bundle: inout ResolvedWorkflowBundle,
  instance: EffectiveWorkflowInstance?,
  workingDirectory: String,
  mockScenarioPath: String?,
  calleeResolver: any WorkflowCalleeResolving,
  baseEnvironment: [String: String]? = nil
) async throws -> SessionKaibaPreflightContext {
  let configuration = instance?.configuration ?? WorkflowInstanceConfiguration()
  let resolvedWorkingDirectory = configuration.normalizedWorkingDirectory ?? workingDirectory
  bundle.workflow.nodes = try WorkflowInstanceResolver.applyKaibaInstancePatches(
    configuration.nodePatches,
    to: bundle.workflow.nodes
  )
  var environment = baseEnvironment ?? CLIRuntimeEnvironment.mergedProcessEnvironment()
  if let path = configuration.environmentFilePath?.trimmingCharacters(in: .whitespacesAndNewlines),
     !path.isEmpty {
    environment.merge(
      try parseEnvironmentFile(
        absoluteURL(path, relativeTo: URL(fileURLWithPath: resolvedWorkingDirectory, isDirectory: true))
      )
    ) { _, fileValue in fileValue }
  }
  environment.merge(configuration.environmentVariables) { _, instanceValue in instanceValue }
  let snapshot: KaibaExecutionSnapshot?
  if mockScenarioPath == nil {
    do {
      snapshot = try await KaibaExecutionPreflight.workflow(
        nodes: bundle.workflow.nodes,
        environment: environment,
        workflow: bundle.workflow,
        calleeResolver: calleeResolver
      )
    } catch {
      if let preflight = CLIUsageError.kaibaPreflight(error) {
        throw preflight
      }
      throw error
    }
  } else {
    snapshot = nil
  }
  return SessionKaibaPreflightContext(
    workingDirectory: resolvedWorkingDirectory,
    environment: environment,
    snapshot: snapshot
  )
}

func withSessionKaibaSnapshot<Value: Sendable>(
  _ context: SessionKaibaPreflightContext,
  mockScenarioPath: String?,
  operation: () async throws -> Value
) async rethrows -> Value {
  try await KaibaAddonExecutionContext.withSnapshot(
    context.snapshot,
    allowsMockExecution: mockScenarioPath != nil,
    operation: operation
  )
}
