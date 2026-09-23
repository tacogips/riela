import Foundation

extension DeterministicWorkflowRunner {
  func executePlacedAdapter(
    _ input: AdapterExecutionInput, step: WorkflowStepRef, executionId: String, context: AdapterExecutionContext
  ) async throws -> AdapterExecutionOutput {
    guard let placement = step.placement else { return try await adapter.execute(input, context: context) }
    guard case let .adapter(output) = try await remote(.adapter(input), executionId: executionId, placement: placement, context: context) else {
      throw AdapterExecutionError(.invalidOutput, "remote adapter returned an incompatible result")
    }
    return output
  }

  func executePlacedAddon(
    _ input: WorkflowAddonExecutionInput, step: WorkflowStepRef, executionId: String, context: AdapterExecutionContext
  ) async throws -> AdapterExecutionOutput {
    guard let placement = step.placement else {
      guard let addonResolver else { throw AdapterExecutionError(.providerError, "missing add-on resolver") }
      return try await addonResolver.execute(input, context: context)
    }
    guard case let .adapter(output) = try await remote(.addon(input), executionId: executionId, placement: placement, context: context) else {
      throw AdapterExecutionError(.invalidOutput, "remote add-on returned an incompatible result")
    }
    return output
  }

  func executePlacedStdio(
    _ input: WorkflowStdioNodeExecutionInput, step: WorkflowStepRef, executionId: String, context: AdapterExecutionContext
  ) async throws -> WorkflowStdioNodeExecutionResult {
    guard let placement = step.placement else {
      guard let stdioNodeExecutor else { throw AdapterExecutionError(.providerError, "missing stdio executor") }
      return try await stdioNodeExecutor.execute(input, context: context)
    }
    guard case let .stdio(output) = try await remote(.stdio(input), executionId: executionId, placement: placement, context: context) else {
      throw AdapterExecutionError(.invalidOutput, "remote command returned an incompatible result")
    }
    return output
  }

  private func remote(
    _ invocation: DistributedNodeInvocation, executionId: String,
    placement: DistributedExecutionPlacement, context: AdapterExecutionContext
  ) async throws -> DistributedNodeOutput {
    guard let distributedExecutor else {
      throw AdapterExecutionError(.providerError, "step specifies a remote worker but no controller is configured")
    }
    return try await distributedExecutor.execute(invocation, executionId: executionId, placement: placement, context: context)
  }
}
