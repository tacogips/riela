import RielaCore

extension BuiltinWorkflowAddonResolver {
  func executeStatefulAddonIfSupported(
    _ input: WorkflowAddonExecutionInput
  ) async throws -> AdapterExecutionOutput? {
    if input.addon.name == "riela/x-digest" {
      return try executeXDigest(input)
    }
    if input.addon.name == "riela/gmail-digest" {
      return try await executeGmailDigest(input)
    }
    if let memoryAddon = BuiltinMemoryAddon(rawValue: input.addon.name) {
      return try executeMemoryAddon(input, operation: memoryAddon)
    }
    if let keyValueAddon = BuiltinKeyValueAddon(rawValue: input.addon.name) {
      return try executeKeyValueAddon(input, operation: keyValueAddon)
    }
    if let routineAddon = BuiltinRoutineAddon(rawValue: input.addon.name) {
      return try executeRoutineAddon(input, operation: routineAddon)
    }
    return nil
  }
}
