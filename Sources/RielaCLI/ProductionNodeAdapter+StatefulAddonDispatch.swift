import RielaCore

extension BuiltinWorkflowAddonResolver {
  func executeStatefulAddonIfSupported(
    _ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext
  ) async throws -> AdapterExecutionOutput? {
    guard let handler = BuiltinStatefulAddonRegistry.handlers[input.addon.name] else { return nil }
    return try await handler(self, input, context)
  }
}
