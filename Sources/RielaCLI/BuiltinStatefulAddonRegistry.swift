import RielaCore

/// Feature implementations declare their names and handlers. Dispatch only
/// looks up a registration and forwards the unchanged execution context.
struct BuiltinAddonHandlerRegistration: Sendable {
  typealias Handler = @Sendable (BuiltinWorkflowAddonResolver, WorkflowAddonExecutionInput, AdapterExecutionContext) async throws -> AdapterExecutionOutput
  let name: String
  let handler: Handler
  let bindsCLIVariablesAsInputs: Bool

  init(name: String, bindsCLIVariablesAsInputs: Bool = true, handler: @escaping Handler) {
    self.name = name; self.handler = handler; self.bindsCLIVariablesAsInputs = bindsCLIVariablesAsInputs
  }

  static func family<Operation: CaseIterable & RawRepresentable & Sendable>(
    _ type: Operation.Type,
    handler: @escaping @Sendable (BuiltinWorkflowAddonResolver, WorkflowAddonExecutionInput, Operation, AdapterExecutionContext) async throws -> AdapterExecutionOutput
  ) -> [Self] where Operation.RawValue == String {
    type.allCases.map { operation in
      Self(name: operation.rawValue, handler: { resolver, input, context in
        try await handler(resolver, input, operation, context)
      })
    }
  }
}

enum BuiltinStatefulAddonRegistry {
  static let registrations: [BuiltinAddonHandlerRegistration] = [
    BuiltinWorkflowAddonResolver.xCollectionRegistration,
    BuiltinWorkflowAddonResolver.gmailCollectionRegistration,
    BuiltinWorkflowAddonResolver.jsonRouteRegistration,
    BuiltinWorkflowAddonResolver.pageStateRegistration,
    BuiltinWorkflowAddonResolver.collectionCheckpointRegistration,
    BuiltinWorkflowAddonResolver.snapshotStoreRegistration,
    BuiltinWorkflowAddonResolver.snapshotScanRegistration,
    BuiltinWorkflowAddonResolver.arraySelectRegistration,
    BuiltinWorkflowAddonResolver.snapshotRotateRegistration,
    BuiltinWorkflowAddonResolver.cacheExchangeRegistration,
    BuiltinWorkflowAddonResolver.recordManifestRegistration,
    BuiltinWorkflowAddonResolver.publicWebRegistration,
    BuiltinWorkflowAddonResolver.webCollectionRegistration,
    BuiltinWorkflowAddonResolver.xDigestRegistration,
    BuiltinWorkflowAddonResolver.gmailDigestRegistration
  ] + BuiltinAddonHandlerRegistration.family(BuiltinDataAddon.self) { resolver, input, operation, _ in
    try resolver.executeDataAddon(input, operation: operation)
  } + BuiltinAddonHandlerRegistration.family(BuiltinMemoryAddon.self) { resolver, input, operation, _ in
    try resolver.executeMemoryAddon(input, operation: operation)
  } + BuiltinAddonHandlerRegistration.family(BuiltinCacheAddon.self) { resolver, input, operation, _ in
    try resolver.executeCacheAddon(input, operation: operation)
  } + BuiltinAddonHandlerRegistration.family(BuiltinKeyValueAddon.self) { resolver, input, operation, _ in
    try resolver.executeKeyValueAddon(input, operation: operation)
  } + BuiltinAddonHandlerRegistration.family(BuiltinRoutineAddon.self) { resolver, input, operation, _ in
    try resolver.executeRoutineAddon(input, operation: operation)
  }

  static let handlers = Dictionary(uniqueKeysWithValues: registrations.map { ($0.name, $0.handler) })
}
