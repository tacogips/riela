import Crypto
import Foundation
import RielaCore
import RielaGraphQL

public struct FileWorkflowRegistryGraphQLProvider: WorkflowRegistryGraphQLProviding, Sendable {
  private static let processRetainKey = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })

  public var workingDirectory: String
  private let webPrincipalId: String?
  private let retainKey: Data

  public init(
    workingDirectory: String = FileManager.default.currentDirectoryPath,
    webPrincipalId: String? = nil,
    retainKey: Data? = nil
  ) {
    self.workingDirectory = workingDirectory
    self.webPrincipalId = webPrincipalId
    self.retainKey = retainKey ?? Self.processRetainKey
  }

  public func workflows(filter: WorkflowRegistryFilter) async throws -> [GraphQLWorkflowRegistryEntry] {
    let effectiveFilter = try webFilter(filter)
    return try WorkflowRegistryService()
      .list(filter: effectiveFilter, workingDirectory: workingDirectory)
      .map { try project($0, includeDefinition: false) }
  }

  public func workflow(target: WorkflowRegistryTarget) async throws -> GraphQLWorkflowRegistryEntry {
    try requireWebTargetIfNeeded(target)
    let entry = try WorkflowRegistryService().fetch(
      target: target,
      workingDirectory: workingDirectory
    )
    if webPrincipalId != nil {
      try requireWebMutableEntry(entry)
    }
    return try project(entry)
  }

  public func registerMutableWorkflow(
    input: GraphQLRegisterMutableWorkflowInput,
    resolvedBundleURL: URL
  ) async throws -> GraphQLWorkflowMutationPayload {
    if let principalId = webPrincipalId {
      guard input.definition != nil, input.bundle == nil else {
        throw registryError(.unsupportedBundleReference, "web registration requires an inline definition")
      }
      let definition = try decodedDefinition(at: resolvedBundleURL)
      guard !containsRetainHandle(definition) else {
        throw registryError(.invalidWorkflow, "retain handles are not valid during registration")
      }
      try requireMutableEditProjectionFits(
        definition,
        originId: "registration-preflight",
        revision: "registration-preflight",
        principalId: principalId
      )
    }
    let activation = input.activationState.flatMap {
      WorkflowActivationState(rawValue: $0.rawValue.lowercased())
    }
    do {
      return try projectMutation(WorkflowRegistryService().register(
        input: resolvedBundleURL,
        overwrite: input.overwrite ?? false,
        activationState: activation,
        workingDirectory: workingDirectory
      ))
    } catch let error as WorkflowResolutionError {
      if webPrincipalId != nil {
        throw registryError(.invalidWorkflow, "workflow bundle failed validation")
      }
      throw error
    }
  }

  public func updateMutableWorkflow(
    input: GraphQLUpdateMutableWorkflowInput,
    resolvedBundleURL: URL
  ) async throws -> GraphQLWorkflowMutationPayload {
    if let principalId = webPrincipalId {
      try requireWebTarget(input.target.registryTarget)
      guard input.definition != nil, input.bundle == nil else {
        throw registryError(.unsupportedBundleReference, "web updates require an inline definition")
      }
      guard let expectedRevision = input.expectedDefinitionRevision else {
        throw registryError(.registryConflict, "expectedDefinitionRevision is required")
      }
      let submitted = try decodedDefinition(at: resolvedBundleURL)
      return try projectMutation(WorkflowRegistryService().updateDefinition(
        target: input.target.registryTarget,
        expectedDefinitionRevision: expectedRevision,
        workingDirectory: workingDirectory
      ) { currentData, entry in
        let current = try JSONDecoder().decode(JSONValue.self, from: currentData)
        let expanded = try expandRetainHandles(
          submitted,
          currentRoot: current,
          originId: entry.originId,
          revision: expectedRevision,
          principalId: principalId,
          path: ""
        )
        try WorkflowRegistryDefinitionInputPolicy.validate(expanded)
        let replacement = try sortedJSONData(expanded)
        try requireMutableEditProjectionFits(
          expanded,
          originId: entry.originId,
          revision: WorkflowHistoryCanonicalCoding.sha256(replacement),
          principalId: principalId
        )
        return replacement
      })
    }
    return try projectMutation(WorkflowRegistryService().update(
      target: input.target.registryTarget,
      input: resolvedBundleURL,
      workingDirectory: workingDirectory
    ))
  }

  public func deleteMutableWorkflow(
    input: GraphQLDeleteMutableWorkflowInput
  ) async throws -> GraphQLWorkflowMutationPayload {
    if webPrincipalId != nil {
      try requireWebTarget(input.target.registryTarget)
      guard input.expectedDefinitionRevision != nil else {
        throw registryError(.registryConflict, "expectedDefinitionRevision is required")
      }
    }
    return try projectMutation(WorkflowRegistryService().delete(
      target: input.target.registryTarget,
      expectedDefinitionRevision: input.expectedDefinitionRevision,
      workingDirectory: workingDirectory
    ))
  }

  public func setWorkflowActivation(
    input: GraphQLSetWorkflowActivationInput,
    state: WorkflowActivationState
  ) async throws -> GraphQLWorkflowMutationPayload {
    if webPrincipalId != nil {
      try requireWebMutableTarget(input.target.registryTarget)
      guard input.expectedDefinitionRevision != nil, input.expectedActivationState != nil else {
        throw registryError(
          .registryConflict,
          "expectedDefinitionRevision and expectedActivationState are required"
        )
      }
    }
    return try projectMutation(WorkflowRegistryService().setActivation(
      state,
      target: input.target.registryTarget,
      expectedDefinitionRevision: input.expectedDefinitionRevision,
      expectedActivationState: input.expectedActivationState.flatMap {
        WorkflowActivationState(rawValue: $0.rawValue.lowercased())
      },
      workingDirectory: workingDirectory
    ))
  }

  public func consolidateWorkflows(
    input: GraphQLConsolidateWorkflowsInput,
    resolvedBundleURL: URL
  ) async throws -> GraphQLWorkflowMutationPayload {
    guard webPrincipalId == nil else {
      throw registryError(.forbidden, "consolidateWorkflows is unavailable from the web")
    }
    guard let retireMode = WorkflowRetireMode(rawValue: input.retireMode.rawValue.lowercased()) else {
      throw registryError(.invalidRetireMode, "retireMode must be DEACTIVATE or DELETE")
    }
    return try projectMutation(WorkflowRegistryService().consolidate(
      sources: input.sources.map(\.registryTarget),
      replacement: resolvedBundleURL,
      retireMode: retireMode,
      activateReplacement: input.activateReplacement ?? true,
      workingDirectory: workingDirectory
    ))
  }

  private func webFilter(_ filter: WorkflowRegistryFilter) throws -> WorkflowRegistryFilter {
    guard webPrincipalId != nil else { return filter }
    guard filter.scope == nil || filter.scope == .user,
          filter.provenance == nil || filter.provenance == .mutable,
          filter.mutable != false,
          filter.sourceKind == nil || filter.sourceKind == .workflow else {
      throw registryError(.invalidFilter, "web registry access is restricted to user mutable workflows")
    }
    return WorkflowRegistryFilter(
      query: filter.query,
      description: filter.description,
      scope: .user,
      sourceKind: .workflow,
      provenance: .mutable,
      mutable: true,
      activationState: filter.activationState
    )
  }

  private func requireWebTargetIfNeeded(_ target: WorkflowRegistryTarget) throws {
    if webPrincipalId != nil { try requireWebTarget(target) }
  }

  private func requireWebTarget(_ target: WorkflowRegistryTarget) throws {
    guard target.scope == .user, let originId = target.originId, !originId.isEmpty else {
      throw registryError(.invalidOrigin, "an exact user mutable origin is required")
    }
  }

  private func requireWebMutableTarget(_ target: WorkflowRegistryTarget) throws {
    try requireWebTarget(target)
    let entry = try WorkflowRegistryService().fetch(
      target: target,
      workingDirectory: workingDirectory
    )
    try requireWebMutableEntry(entry)
  }

  private func requireWebMutableEntry(_ entry: WorkflowCatalogEntry) throws {
    guard entry.provenance == .mutable else {
      throw registryError(.immutableWorkflow, "web registry access requires a mutable workflow")
    }
  }

  private func projectMutation(
    _ result: WorkflowRegistryMutationResult
  ) throws -> GraphQLWorkflowMutationPayload {
    let includeDefinition = webPrincipalId == nil
    return GraphQLWorkflowMutationPayload(
      accepted: result.accepted,
      overwritten: result.overwritten,
      workflow: try result.workflow.map {
        try project($0, includeDefinition: includeDefinition)
      },
      retiredWorkflows: try result.retiredWorkflows.map { try project($0, includeDefinition: false) },
      errors: result.errors
    )
  }

  private func project(
    _ entry: WorkflowCatalogEntry,
    includeDefinition: Bool = true
  ) throws -> GraphQLWorkflowRegistryEntry {
    var definition: JSONObject?
    var revision: String?
    if includeDefinition, let principalId = webPrincipalId, entry.mutable {
      let snapshot = try WorkflowRegistryService().definitionSnapshot(
        target: WorkflowRegistryTarget(
          workflowId: entry.workflowId,
          scope: .user,
          originId: entry.originId
        ),
        workingDirectory: workingDirectory
      )
      let decoded = try JSONDecoder().decode(JSONValue.self, from: snapshot.data)
      try WorkflowRegistryDefinitionInputPolicy.validate(decoded)
      guard case let .object(projected) = projectDefinition(
        decoded,
        originId: entry.originId,
        revision: snapshot.revision,
        principalId: principalId,
        path: ""
      ) else {
        throw registryError(.invalidWorkflow, "mutable workflow definition must be an object")
      }
      let projectedData = try JSONEncoder().encode(JSONValue.object(projected))
      guard projectedData.count <= WorkflowWebProjectionPolicy.definitionResponseLimit else {
        throw registryError(.invalidWorkflow, "mutable workflow edit projection exceeds 512 KiB")
      }
      definition = projected
      revision = snapshot.revision
    }
    return GraphQLWorkflowRegistryEntry(
      originId: entry.originId,
      workflowId: entry.workflowId,
      name: entry.workflowName,
      description: safeDisplayText(entry.description),
      scope: entry.scope.rawValue.uppercased(),
      sourceKind: entry.sourceKind.rawValue.uppercased(),
      provenance: entry.provenance.rawValue.uppercased(),
      mutable: entry.mutable,
      activationState: entry.activationState.rawValue.uppercased(),
      valid: entry.valid,
      packageName: entry.packageName,
      packageVersion: entry.packageVersion,
      definition: definition,
      definitionRevision: revision,
      diagnostics: entry.diagnostics.prefix(100).map {
        let summary = WorkflowWebProjectionPolicy().persistedSummary(
          $0.message,
          context: .registryDiagnostic
        )
        return GraphQLWorkflowRegistryDiagnostic(
          severity: $0.severity.rawValue,
          path: relativeDiagnosticPath($0.path),
          message: summary.value
        )
      }
    )
  }

  private func projectDefinition(
    _ value: JSONValue,
    originId: String,
    revision: String,
    principalId: String,
    path: String
  ) -> JSONValue {
    switch value {
    case let .object(object):
      var result: JSONObject = [:]
      for (key, child) in object {
        let childPath = "\(path)/\(jsonPointerEscape(key))"
        switch definitionFieldExposure(at: childPath) {
        case .structural:
          result[key] = projectDefinition(
            child,
            originId: originId,
            revision: revision,
            principalId: principalId,
            path: childPath
          )
        case .displayText:
          if case let .string(text) = child, let safe = safeDisplayText(text) {
            result[key] = .string(safe)
          } else {
            result[key] = retainPlaceholder(
              child,
              originId: originId,
              revision: revision,
              principalId: principalId,
              path: childPath
            )
          }
        case .sensitive:
          result[key] = retainPlaceholder(
            child,
            originId: originId,
            revision: revision,
            principalId: principalId,
            path: childPath
          )
        }
      }
      return .object(result)
    case let .array(values):
      return .array(values.enumerated().map { index, child in
        projectDefinition(
          child,
          originId: originId,
          revision: revision,
          principalId: principalId,
          path: "\(path)/\(index)"
        )
      })
    case let .string(text):
      return safeDisplayText(text).map(JSONValue.string)
        ?? retainPlaceholder(
          value,
          originId: originId,
          revision: revision,
          principalId: principalId,
          path: path
        )
    default:
      return value
    }
  }

  private func expandRetainHandles(
    _ value: JSONValue,
    currentRoot: JSONValue,
    originId: String,
    revision: String,
    principalId: String,
    path: String
  ) throws -> JSONValue {
    if case let .object(object) = value, object["$rielaRetain"] != nil {
      guard object.count == 1,
            case let .string(handle)? = object["$rielaRetain"],
            let retained = jsonValue(at: path, in: currentRoot),
            constantTimeEqual(
              handle,
              retainHandle(
                retained,
                originId: originId,
                revision: revision,
                principalId: principalId,
                path: path
              )
            ) else {
        throw registryError(.invalidWorkflow, "retain handle is invalid, moved, replayed, or rebound")
      }
      return retained
    }
    switch value {
    case let .object(object):
      var expanded: JSONObject = [:]
      for (key, child) in object {
        expanded[key] = try expandRetainHandles(
          child,
          currentRoot: currentRoot,
          originId: originId,
          revision: revision,
          principalId: principalId,
          path: "\(path)/\(jsonPointerEscape(key))"
        )
      }
      return .object(expanded)
    case let .array(values):
      return .array(try values.enumerated().map { index, child in
        try expandRetainHandles(
          child,
          currentRoot: currentRoot,
          originId: originId,
          revision: revision,
          principalId: principalId,
          path: "\(path)/\(index)"
        )
      })
    default:
      return value
    }
  }

  private func retainPlaceholder(
    _ value: JSONValue,
    originId: String,
    revision: String,
    principalId: String,
    path: String
  ) -> JSONValue {
    .object([
      "$rielaRetain": .string(retainHandle(
        value,
        originId: originId,
        revision: revision,
        principalId: principalId,
        path: path
      ))
    ])
  }

  private func retainHandle(
    _ value: JSONValue,
    originId: String,
    revision: String,
    principalId: String,
    path: String
  ) -> String {
    let digest = WorkflowHistoryCanonicalCoding.sha256((try? sortedJSONData(value)) ?? Data())
    let binding = [principalId, originId, revision, path, digest].joined(separator: "\u{0}")
    let authentication = HMAC<SHA256>.authenticationCode(
      for: Data(binding.utf8),
      using: SymmetricKey(data: retainKey)
    )
    return Data(authentication).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf8)
    let right = Array(rhs.utf8)
    guard left.count == right.count else { return false }
    return zip(left, right).reduce(UInt8.zero) { $0 | ($1.0 ^ $1.1) } == 0
  }

  private enum DefinitionFieldExposure {
    case structural
    case displayText
    case sensitive
  }

  private func definitionFieldExposure(at path: String) -> DefinitionFieldExposure {
    if path == "/description"
      || path.range(
        of: #"^/steps/[0-9]+/description$"#,
        options: .regularExpression
      ) != nil
      || path.range(
        of: #"^/steps/[0-9]+/transitions/[0-9]+/label$"#,
        options: .regularExpression
      ) != nil {
      return .displayText
    }
    let exactStructuralPaths: Set<String> = [
      "/workflowId", "/schemaVersion", "/entryStepId", "/managerStepId",
      "/defaults", "/defaults/nodeTimeoutMs", "/defaults/maxLoopIterations",
      "/defaults/fanoutConcurrency", "/nodes", "/steps"
    ]
    if exactStructuralPaths.contains(path) { return .structural }
    let structuralPatterns = [
      #"^/nodes/[0-9]+$"#,
      #"^/nodes/[0-9]+/(id|nodeFile|kind)$"#,
      #"^/nodes/[0-9]+/nodeRef$"#,
      #"^/nodes/[0-9]+/nodeRef/(workflowId|nodeId)$"#,
      #"^/nodes/[0-9]+/execution$"#,
      #"^/nodes/[0-9]+/execution/(mode|decisionBy)$"#,
      #"^/steps/[0-9]+$"#,
      #"^/steps/[0-9]+/(id|stepFile|nodeId|role|timeoutMs|stallTimeoutMs|failurePolicy|promptVariant)$"#,
      #"^/steps/[0-9]+/sessionPolicy$"#,
      #"^/steps/[0-9]+/sessionPolicy/(mode|inheritFromStepId)$"#,
      #"^/steps/[0-9]+/transitions$"#,
      #"^/steps/[0-9]+/transitions/[0-9]+$"#,
      #"^/steps/[0-9]+/transitions/[0-9]+/(toStepId|toWorkflowId|resumeStepId)$"#
    ]
    return structuralPatterns.contains {
      path.range(of: $0, options: .regularExpression) != nil
    } ? .structural : .sensitive
  }

  private func requireMutableEditProjectionFits(
    _ definition: JSONValue,
    originId: String,
    revision: String,
    principalId: String
  ) throws {
    guard case let .object(projected) = projectDefinition(
      definition,
      originId: originId,
      revision: revision,
      principalId: principalId,
      path: ""
    ) else {
      throw registryError(.invalidWorkflow, "mutable workflow definition must be an object")
    }
    let projectedData = try JSONEncoder().encode(JSONValue.object(projected))
    guard projectedData.count <= WorkflowWebProjectionPolicy.definitionResponseLimit else {
      throw registryError(.invalidWorkflow, "mutable workflow edit projection exceeds 512 KiB")
    }
  }

  private func safeDisplayText(_ value: String?) -> String? {
    guard let value else { return nil }
    let projected = WorkflowWebProjectionPolicy().displayText(value)
    return projected.value == "<redacted>" || projected.truncated ? nil : projected.value
  }

  private func relativeDiagnosticPath(_ path: String) -> String? {
    guard !path.hasPrefix("/") else { return nil }
    return String(path.prefix(256))
  }

  private func definitionData(at directory: URL) throws -> Data {
    let data = try Data(contentsOf: directory.appendingPathComponent("workflow.json"))
    guard data.count <= 512 * 1_024 else {
      throw registryError(.invalidWorkflow, "workflow definition exceeds 512 KiB")
    }
    return data
  }

  private func decodedDefinition(at directory: URL) throws -> JSONValue {
    let definition = try JSONDecoder().decode(
      JSONValue.self,
      from: definitionData(at: directory)
    )
    try WorkflowRegistryDefinitionInputPolicy.validate(definition)
    return definition
  }

  private func sortedJSONData(_ value: JSONValue) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }

  private func containsRetainHandle(_ value: JSONValue) -> Bool {
    switch value {
    case let .object(object):
      return object["$rielaRetain"] != nil || object.values.contains(where: containsRetainHandle)
    case let .array(values):
      return values.contains(where: containsRetainHandle)
    default:
      return false
    }
  }

  private func jsonValue(at pointer: String, in root: JSONValue) -> JSONValue? {
    guard !pointer.isEmpty else { return root }
    return pointer.split(separator: "/", omittingEmptySubsequences: true).reduce(Optional(root)) { value, part in
      guard let value else { return nil }
      let component = String(part)
        .replacingOccurrences(of: "~1", with: "/")
        .replacingOccurrences(of: "~0", with: "~")
      switch value {
      case let .object(object):
        return object[component]
      case let .array(values):
        guard let index = Int(component), values.indices.contains(index) else { return nil }
        return values[index]
      default:
        return nil
      }
    }
  }

  private func jsonPointerEscape(_ value: String) -> String {
    value.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
  }

  private func registryError(
    _ code: WorkflowRegistryErrorCode,
    _ message: String
  ) -> WorkflowRegistryError {
    WorkflowRegistryError(code: code, message: message)
  }
}
