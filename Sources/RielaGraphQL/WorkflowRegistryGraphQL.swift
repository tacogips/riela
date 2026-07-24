import Foundation
import RielaCore

public enum GraphQLWorkflowBundleReferenceKind: String, Codable, Equatable, Sendable {
  case localPath = "LOCAL_PATH"
  case managedReference = "MANAGED_REFERENCE"
}

public enum GraphQLWorkflowRegistryScope: String, Codable, Equatable, Sendable {
  case auto = "AUTO"
  case project = "PROJECT"
  case user = "USER"
}

public enum GraphQLWorkflowRegistrySourceKind: String, Codable, Equatable, Sendable {
  case workflow = "WORKFLOW"
  case package = "PACKAGE"
}

public enum GraphQLWorkflowProvenance: String, Codable, Equatable, Sendable {
  case mutable = "MUTABLE"
  case immutable = "IMMUTABLE"
}

public enum GraphQLWorkflowActivationState: String, Codable, Equatable, Sendable {
  case active = "ACTIVE"
  case deactivated = "DEACTIVATED"
}

public enum GraphQLWorkflowRetireMode: String, Codable, Equatable, Sendable {
  case deactivate = "DEACTIVATE"
  case delete = "DELETE"
}

public struct GraphQLWorkflowBundleReferenceInput: Codable, Equatable, Sendable {
  public var kind: GraphQLWorkflowBundleReferenceKind
  public var value: String

  public init(kind: GraphQLWorkflowBundleReferenceKind, value: String) {
    self.kind = kind
    self.value = value
  }
}

public struct GraphQLWorkflowTargetInput: Codable, Equatable, Sendable {
  public var workflowId: String
  public var scope: GraphQLWorkflowRegistryScope?
  public var originId: String?

  public init(
    workflowId: String,
    scope: GraphQLWorkflowRegistryScope? = nil,
    originId: String? = nil
  ) {
    self.workflowId = workflowId
    self.scope = scope
    self.originId = originId
  }

  public var registryTarget: WorkflowRegistryTarget {
    WorkflowRegistryTarget(
      workflowId: workflowId,
      scope: WorkflowRegistryScope(rawValue: scope?.rawValue.lowercased() ?? "auto") ?? .auto,
      originId: originId
    )
  }
}

public struct GraphQLWorkflowFilterInput: Codable, Equatable, Sendable {
  public var query: String?
  public var description: String?
  public var scope: GraphQLWorkflowRegistryScope?
  public var sourceKind: GraphQLWorkflowRegistrySourceKind?
  public var provenance: GraphQLWorkflowProvenance?
  public var mutable: Bool?
  public var activationState: GraphQLWorkflowActivationState?

  public init(
    query: String? = nil,
    description: String? = nil,
    scope: GraphQLWorkflowRegistryScope? = nil,
    sourceKind: GraphQLWorkflowRegistrySourceKind? = nil,
    provenance: GraphQLWorkflowProvenance? = nil,
    mutable: Bool? = nil,
    activationState: GraphQLWorkflowActivationState? = nil
  ) {
    self.query = query
    self.description = description
    self.scope = scope
    self.sourceKind = sourceKind
    self.provenance = provenance
    self.mutable = mutable
    self.activationState = activationState
  }

  public var registryFilter: WorkflowRegistryFilter {
    WorkflowRegistryFilter(
      query: query,
      description: description,
      scope: scope.flatMap { WorkflowRegistryScope(rawValue: $0.rawValue.lowercased()) },
      sourceKind: sourceKind.flatMap { WorkflowRegistrySourceKind(rawValue: $0.rawValue.lowercased()) },
      provenance: provenance.flatMap { WorkflowProvenance(rawValue: $0.rawValue.lowercased()) },
      mutable: mutable,
      activationState: activationState.flatMap { WorkflowActivationState(rawValue: $0.rawValue.lowercased()) }
    )
  }
}

public struct GraphQLRegisterMutableWorkflowInput: Codable, Equatable, Sendable {
  public var bundle: GraphQLWorkflowBundleReferenceInput
  public var overwrite: Bool?
  public var activationState: GraphQLWorkflowActivationState?
}

public struct GraphQLUpdateMutableWorkflowInput: Codable, Equatable, Sendable {
  public var target: GraphQLWorkflowTargetInput
  public var bundle: GraphQLWorkflowBundleReferenceInput
}

public struct GraphQLDeleteMutableWorkflowInput: Codable, Equatable, Sendable {
  public var target: GraphQLWorkflowTargetInput
}

public struct GraphQLSetWorkflowActivationInput: Codable, Equatable, Sendable {
  public var target: GraphQLWorkflowTargetInput
}

public struct GraphQLConsolidateWorkflowsInput: Codable, Equatable, Sendable {
  public var sources: [GraphQLWorkflowTargetInput]
  public var replacement: GraphQLWorkflowBundleReferenceInput
  public var retireMode: GraphQLWorkflowRetireMode
  public var activateReplacement: Bool?
}

public struct GraphQLWorkflowRegistryDiagnostic: Codable, Equatable, Sendable {
  public var severity: String
  public var path: String?
  public var message: String

  public init(severity: String, path: String? = nil, message: String) {
    self.severity = severity
    self.path = path
    self.message = message
  }
}

public struct GraphQLWorkflowRegistryEntry: Codable, Equatable, Sendable {
  public var originId: String
  public var workflowId: String
  public var name: String
  public var description: String?
  public var scope: String
  public var sourceKind: String
  public var provenance: String
  public var mutable: Bool
  public var activationState: String
  public var valid: Bool
  public var packageName: String?
  public var packageVersion: String?
  public var diagnostics: [GraphQLWorkflowRegistryDiagnostic]

  public init(
    originId: String,
    workflowId: String,
    name: String,
    description: String? = nil,
    scope: String,
    sourceKind: String,
    provenance: String,
    mutable: Bool,
    activationState: String,
    valid: Bool,
    packageName: String? = nil,
    packageVersion: String? = nil,
    diagnostics: [GraphQLWorkflowRegistryDiagnostic] = []
  ) {
    self.originId = originId
    self.workflowId = workflowId
    self.name = name
    self.description = description
    self.scope = scope
    self.sourceKind = sourceKind
    self.provenance = provenance
    self.mutable = mutable
    self.activationState = activationState
    self.valid = valid
    self.packageName = packageName
    self.packageVersion = packageVersion
    self.diagnostics = diagnostics
  }
}

public struct GraphQLWorkflowListPayload: Codable, Equatable, Sendable {
  public var workflows: [GraphQLWorkflowRegistryEntry]
  public var errors: [WorkflowRegistryError]
}

public struct GraphQLWorkflowQueryPayload: Codable, Equatable, Sendable {
  public var workflow: GraphQLWorkflowRegistryEntry?
  public var errors: [WorkflowRegistryError]
}

public struct GraphQLWorkflowMutationPayload: Codable, Equatable, Sendable {
  public var accepted: Bool
  public var overwritten: Bool
  public var workflow: GraphQLWorkflowRegistryEntry?
  public var retiredWorkflows: [GraphQLWorkflowRegistryEntry]
  public var errors: [WorkflowRegistryError]

  public init(
    accepted: Bool,
    overwritten: Bool = false,
    workflow: GraphQLWorkflowRegistryEntry? = nil,
    retiredWorkflows: [GraphQLWorkflowRegistryEntry] = [],
    errors: [WorkflowRegistryError] = []
  ) {
    self.accepted = accepted
    self.overwritten = overwritten
    self.workflow = workflow
    self.retiredWorkflows = retiredWorkflows
    self.errors = errors
  }
}

public protocol WorkflowRegistryGraphQLProviding: Sendable {
  func workflows(filter: WorkflowRegistryFilter) async throws -> [GraphQLWorkflowRegistryEntry]
  func workflow(target: WorkflowRegistryTarget) async throws -> GraphQLWorkflowRegistryEntry
  func registerMutableWorkflow(
    input: GraphQLRegisterMutableWorkflowInput,
    resolvedBundleURL: URL
  ) async throws -> GraphQLWorkflowMutationPayload
  func updateMutableWorkflow(
    input: GraphQLUpdateMutableWorkflowInput,
    resolvedBundleURL: URL
  ) async throws -> GraphQLWorkflowMutationPayload
  func deleteMutableWorkflow(input: GraphQLDeleteMutableWorkflowInput) async throws -> GraphQLWorkflowMutationPayload
  func setWorkflowActivation(
    input: GraphQLSetWorkflowActivationInput,
    state: WorkflowActivationState
  ) async throws -> GraphQLWorkflowMutationPayload
  func consolidateWorkflows(
    input: GraphQLConsolidateWorkflowsInput,
    resolvedBundleURL: URL
  ) async throws -> GraphQLWorkflowMutationPayload
}

public protocol WorkflowRegistryManagedReferenceResolver: Sendable {
  func resolveManagedReference(_ reference: String) async throws -> URL
}

public enum WorkflowRegistryCapability: String, Codable, Equatable, Hashable, Sendable {
  case readRegistry
  case mutateRegistry
}

public struct WorkflowRegistryVerifiedPrincipal: Equatable, Sendable {
  public var principalId: String
  public var capabilities: Set<WorkflowRegistryCapability>

  public init(principalId: String, capabilities: Set<WorkflowRegistryCapability>) {
    self.principalId = principalId
    self.capabilities = capabilities
  }
}

public protocol WorkflowRegistryGraphQLAuthorizing: Sendable {
  func authorize(bearerCredential: String?) async throws -> WorkflowRegistryVerifiedPrincipal
}

public struct WorkflowRegistryGraphQLServerConfig: Sendable {
  public var provider: any WorkflowRegistryGraphQLProviding
  public var authorizer: any WorkflowRegistryGraphQLAuthorizing
  public var managedReferenceResolver: any WorkflowRegistryManagedReferenceResolver

  public init(
    provider: any WorkflowRegistryGraphQLProviding,
    authorizer: any WorkflowRegistryGraphQLAuthorizing,
    managedReferenceResolver: any WorkflowRegistryManagedReferenceResolver
  ) {
    self.provider = provider
    self.authorizer = authorizer
    self.managedReferenceResolver = managedReferenceResolver
  }
}

public struct GraphQLTransportCredential: Equatable, Sendable {
  let value: String

  public init(_ value: String) {
    self.value = value
  }
}

public struct WorkflowRegistryGraphQLDocumentExecutor: GraphQLDocumentExecuting {
  static let queryFields: Set<String> = ["workflows", "workflow"]
  static let mutationFields: Set<String> = [
    "registerMutableWorkflow", "updateMutableWorkflow", "deleteMutableWorkflow",
    "activateWorkflow", "deactivateWorkflow", "consolidateWorkflows"
  ]

  public var configuration: WorkflowRegistryGraphQLServerConfig?
  public var localProvider: (any WorkflowRegistryGraphQLProviding)?
  public var localManagedReferenceResolver: (any WorkflowRegistryManagedReferenceResolver)?

  public init(
    configuration: WorkflowRegistryGraphQLServerConfig? = nil,
    localProvider: (any WorkflowRegistryGraphQLProviding)? = nil,
    localManagedReferenceResolver: (any WorkflowRegistryManagedReferenceResolver)? = nil
  ) {
    self.configuration = configuration
    self.localProvider = localProvider
    self.localManagedReferenceResolver = localManagedReferenceResolver
  }

  public func execute(_ request: GraphQLDocumentRequest) async -> GraphQLDocumentExecutionResponse {
    let roots: [ParsedNoteGraphQLRootField]
    do {
      if let parsed = request.parsedRootFields {
        roots = parsed
      } else {
        let operations = try parseNoteGraphQLOperations(
          in: request.query,
          operationName: request.operationName,
          variables: request.variables,
          parseArguments: true
        )
        for operation in operations {
          let registryRoots = operation.rootFields.filter {
            Self.queryFields.contains($0.fieldName) || Self.mutationFields.contains($0.fieldName)
          }
          if !registryRoots.isEmpty {
            try Self.validateDocumentRootFields(registryRoots)
          }
        }
        guard let selected = try selectNoteGraphQLOperation(
          operations,
          operationName: request.operationName
        ) else { return .notHandled }
        roots = selected.rootFields
      }
    } catch let error as WorkflowRegistryError {
      return graphQLError(code: error.code.rawValue, message: error.message)
    } catch {
      return graphQLError(code: "INVALID_WORKFLOW", message: "\(error)")
    }
    let registryRoots = roots.filter {
      Self.queryFields.contains($0.fieldName) || Self.mutationFields.contains($0.fieldName)
    }
    guard !registryRoots.isEmpty else { return .notHandled }
    guard request.domainPreflightComplete || registryRoots.count == roots.count else {
      return graphQLError(code: WorkflowRegistryErrorCode.forbidden.rawValue, message: "mixed-domain registry documents are denied")
    }
    do {
      try validateWorkflowRegistryRootFields(registryRoots)
    } catch {
      return graphQLError(code: WorkflowRegistryErrorCode.invalidWorkflow.rawValue, message: "\(error)")
    }
    let requiredCapabilities: Set<WorkflowRegistryCapability>
    do {
      requiredCapabilities = try Self.requiredCapabilities(for: registryRoots)
    } catch {
      return graphQLError(code: WorkflowRegistryErrorCode.forbidden.rawValue, message: "\(error)")
    }
    let provider: any WorkflowRegistryGraphQLProviding
    let managedResolver: (any WorkflowRegistryManagedReferenceResolver)?
    if request.isLocallyTrusted, let localProvider {
      provider = localProvider
      managedResolver = localManagedReferenceResolver
    } else {
      guard let configuration else {
        return graphQLError(
          code: WorkflowRegistryErrorCode.workflowRegistryUnavailable.rawValue,
          message: "workflow registry GraphQL is unavailable"
        )
      }
      let principal: WorkflowRegistryVerifiedPrincipal
      if request.domainPreflightComplete, let verified = request.verifiedRegistryPrincipal {
        principal = verified
      } else {
        guard request.transportCredential != nil else {
          return graphQLError(
            code: WorkflowRegistryErrorCode.unauthenticated.rawValue,
            message: "bearer credential is required"
          )
        }
        do {
          principal = try await configuration.authorizer.authorize(
            bearerCredential: request.transportCredential?.value
          )
        } catch {
          return graphQLError(
            code: WorkflowRegistryErrorCode.unauthenticated.rawValue,
            message: "authentication failed"
          )
        }
      }
      guard requiredCapabilities.isSubset(of: principal.capabilities) else {
        return graphQLError(code: WorkflowRegistryErrorCode.forbidden.rawValue, message: "insufficient capability")
      }
      provider = configuration.provider
      managedResolver = configuration.managedReferenceResolver
    }
    var data: JSONObject = [:]
    for root in registryRoots {
      do {
        let value = try await execute(root: root, request: request, provider: provider, managedResolver: managedResolver)
        data[root.responseKey] = projectRegistryValue(value, selections: root.selections)
      } catch let error as WorkflowRegistryError {
        let value = registryFailureValue(for: root, error: error)
        data[root.responseKey] = projectRegistryValue(value, selections: root.selections)
      } catch is CancellationError {
        return graphQLError(
          code: WorkflowRegistryErrorCode.registryIOFailure.rawValue,
          message: "workflow registry request was cancelled",
          completedData: data
        )
      } catch {
        return graphQLError(
          code: WorkflowRegistryErrorCode.registryIOFailure.rawValue,
          message: "workflow registry provider failed",
          completedData: data
        )
      }
    }
    return GraphQLDocumentExecutionResponse(handled: true, body: ["data": .object(data)])
  }

  func preflight(
    _ request: GraphQLDocumentRequest,
    rootFields: [ParsedNoteGraphQLRootField]
  ) async -> GraphQLDocumentExecutionResponse? {
    switch await authorizeForPreflight(request, rootFields: rootFields) {
    case .authorized:
      return nil
    case let .rejected(response):
      return response
    }
  }

  func authorizeForPreflight(
    _ request: GraphQLDocumentRequest,
    rootFields: [ParsedNoteGraphQLRootField]
  ) async -> WorkflowRegistryPreflightOutcome {
    guard !rootFields.isEmpty,
          rootFields.allSatisfy({ Self.queryFields.contains($0.fieldName) || Self.mutationFields.contains($0.fieldName) }) else {
      return .rejected(graphQLError(
        code: WorkflowRegistryErrorCode.forbidden.rawValue,
        message: "unsupported registry root field"
      ))
    }
    do {
      try validateWorkflowRegistryRootFields(rootFields)
    } catch {
      return .rejected(graphQLError(code: WorkflowRegistryErrorCode.invalidWorkflow.rawValue, message: "\(error)"))
    }
    let requiredCapabilities: Set<WorkflowRegistryCapability>
    do {
      requiredCapabilities = try Self.requiredCapabilities(for: rootFields)
    } catch {
      return .rejected(graphQLError(code: WorkflowRegistryErrorCode.forbidden.rawValue, message: "\(error)"))
    }
    if request.isLocallyTrusted {
      guard localProvider != nil else {
        return .rejected(graphQLError(
          code: WorkflowRegistryErrorCode.workflowRegistryUnavailable.rawValue,
          message: "workflow registry GraphQL is unavailable"
        ))
      }
      return .authorized(nil)
    }
    guard let configuration else {
      return .rejected(graphQLError(
        code: WorkflowRegistryErrorCode.workflowRegistryUnavailable.rawValue,
        message: "workflow registry GraphQL is unavailable"
      ))
    }
    guard request.transportCredential != nil else {
      return .rejected(graphQLError(
        code: WorkflowRegistryErrorCode.unauthenticated.rawValue,
        message: "bearer credential is required"
      ))
    }
    do {
      let principal = try await configuration.authorizer.authorize(
        bearerCredential: request.transportCredential?.value
      )
      guard requiredCapabilities.isSubset(of: principal.capabilities) else {
        return .rejected(graphQLError(
          code: WorkflowRegistryErrorCode.forbidden.rawValue,
          message: "insufficient capability"
        ))
      }
      return .authorized(principal)
    } catch {
      return .rejected(graphQLError(
        code: WorkflowRegistryErrorCode.unauthenticated.rawValue,
        message: "authentication failed"
      ))
    }
  }

  private static func requiredCapabilities(
    for rootFields: [ParsedNoteGraphQLRootField]
  ) throws -> Set<WorkflowRegistryCapability> {
    var required: Set<WorkflowRegistryCapability> = []
    for root in rootFields {
      if queryFields.contains(root.fieldName) {
        guard root.operationType == .query else {
          throw WorkflowRegistryError(
            code: .forbidden,
            message: "registry query field '\(root.fieldName)' is not valid in a mutation operation"
          )
        }
        required.insert(.readRegistry)
      } else if mutationFields.contains(root.fieldName) {
        guard root.operationType == .mutation else {
          throw WorkflowRegistryError(
            code: .forbidden,
            message: "registry mutation field '\(root.fieldName)' is not valid in a query operation"
          )
        }
        required.insert(.mutateRegistry)
      } else {
        throw WorkflowRegistryError(code: .forbidden, message: "unsupported registry root field")
      }
    }
    return required
  }

  static func validateDocumentRootFields(
    _ rootFields: [ParsedNoteGraphQLRootField]
  ) throws {
    try validateWorkflowRegistryRootFields(rootFields)
    _ = try requiredCapabilities(for: rootFields)
  }

  private func execute(
    root: ParsedNoteGraphQLRootField,
    request: GraphQLDocumentRequest,
    provider: any WorkflowRegistryGraphQLProviding,
    managedResolver: (any WorkflowRegistryManagedReferenceResolver)?
  ) async throws -> JSONValue {
    switch root.fieldName {
    case "workflows":
      let input: GraphQLWorkflowFilterInput? = try optionalRegistryInput("filter", arguments: root.arguments)
      return try registryJSONValue(GraphQLWorkflowListPayload(
        workflows: try await provider.workflows(filter: input?.registryFilter ?? WorkflowRegistryFilter()),
        errors: []
      ))
    case "workflow":
      let input: GraphQLWorkflowTargetInput = try requiredRegistryInput("target", arguments: root.arguments)
      return try registryJSONValue(GraphQLWorkflowQueryPayload(
        workflow: try await provider.workflow(target: input.registryTarget),
        errors: []
      ))
    case "registerMutableWorkflow":
      let input: GraphQLRegisterMutableWorkflowInput = try requiredRegistryInput("input", arguments: root.arguments)
      return try await registryJSONValue(provider.registerMutableWorkflow(
        input: input,
        resolvedBundleURL: resolve(input.bundle, request: request, managedResolver: managedResolver)
      ))
    case "updateMutableWorkflow":
      let input: GraphQLUpdateMutableWorkflowInput = try requiredRegistryInput("input", arguments: root.arguments)
      return try await registryJSONValue(provider.updateMutableWorkflow(
        input: input,
        resolvedBundleURL: resolve(input.bundle, request: request, managedResolver: managedResolver)
      ))
    case "deleteMutableWorkflow":
      let input: GraphQLDeleteMutableWorkflowInput = try requiredRegistryInput("input", arguments: root.arguments)
      return try await registryJSONValue(provider.deleteMutableWorkflow(input: input))
    case "activateWorkflow", "deactivateWorkflow":
      let input: GraphQLSetWorkflowActivationInput = try requiredRegistryInput("input", arguments: root.arguments)
      let state: WorkflowActivationState = root.fieldName == "activateWorkflow" ? .active : .deactivated
      return try await registryJSONValue(provider.setWorkflowActivation(input: input, state: state))
    case "consolidateWorkflows":
      let input: GraphQLConsolidateWorkflowsInput = try requiredRegistryInput("input", arguments: root.arguments)
      return try await registryJSONValue(provider.consolidateWorkflows(
        input: input,
        resolvedBundleURL: resolve(input.replacement, request: request, managedResolver: managedResolver)
      ))
    default:
      throw WorkflowRegistryError(code: .invalidWorkflow, message: "unsupported workflow registry field")
    }
  }

  private func resolve(
    _ reference: GraphQLWorkflowBundleReferenceInput,
    request: GraphQLDocumentRequest,
    managedResolver: (any WorkflowRegistryManagedReferenceResolver)?
  ) async throws -> URL {
    guard !reference.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw WorkflowRegistryError(code: .unsupportedBundleReference, message: "bundle reference is empty")
    }
    switch reference.kind {
    case .localPath:
      guard request.isLocallyTrusted else {
        throw WorkflowRegistryError(code: .unsupportedBundleReference, message: "remote LOCAL_PATH is forbidden")
      }
      if reference.value.hasPrefix("/") {
        return URL(fileURLWithPath: reference.value).standardizedFileURL
      }
      let workingDirectory = request.localWorkingDirectory ?? FileManager.default.currentDirectoryPath
      return URL(
        fileURLWithPath: reference.value,
        relativeTo: URL(fileURLWithPath: workingDirectory, isDirectory: true)
      ).standardizedFileURL
    case .managedReference:
      guard let managedResolver else {
        throw WorkflowRegistryError(code: .unsupportedBundleReference, message: "managed reference resolver is unavailable")
      }
      return try await managedResolver.resolveManagedReference(reference.value)
    }
  }
}

public struct CompositeGraphQLDocumentExecutor: GraphQLDocumentExecuting {
  public var workflowRegistry: WorkflowRegistryGraphQLDocumentExecutor
  public var fallback: any GraphQLDocumentExecuting

  public init(
    workflowRegistry: WorkflowRegistryGraphQLDocumentExecutor = WorkflowRegistryGraphQLDocumentExecutor(),
    fallback: any GraphQLDocumentExecuting
  ) {
    self.workflowRegistry = workflowRegistry
    self.fallback = fallback
  }

  public func execute(_ request: GraphQLDocumentRequest) async -> GraphQLDocumentExecutionResponse {
    let operations: [ParsedNoteGraphQLOperation]
    let selectedOperation: ParsedNoteGraphQLOperation
    let roots: [ParsedNoteGraphQLRootField]
    do {
      operations = try parseNoteGraphQLOperations(
        in: request.query,
        operationName: request.operationName,
        variables: request.variables,
        parseArguments: true
      )
      guard let selected = try selectNoteGraphQLOperation(
        operations,
        operationName: request.operationName
      ), !selected.rootFields.isEmpty else {
        return .notHandled
      }
      selectedOperation = selected
      roots = selected.rootFields
    } catch {
      return graphQLError(code: WorkflowRegistryErrorCode.invalidWorkflow.rawValue, message: "\(error)")
    }
    if let error = await preflightUnselectedOperations(
      operations.filter { $0 != selectedOperation },
      request: request
    ) {
      return error
    }
    do {
      try validateUniqueGraphQLRootResponseKeys(roots)
    } catch {
      return graphQLError(code: WorkflowRegistryErrorCode.invalidWorkflow.rawValue, message: "\(error)")
    }
    let registryRoots = roots.filter {
      WorkflowRegistryGraphQLDocumentExecutor.queryFields.contains($0.fieldName)
        || WorkflowRegistryGraphQLDocumentExecutor.mutationFields.contains($0.fieldName)
    }
    let fallbackRoots = roots.filter { root in
      !WorkflowRegistryGraphQLDocumentExecutor.queryFields.contains(root.fieldName)
        && !WorkflowRegistryGraphQLDocumentExecutor.mutationFields.contains(root.fieldName)
    }
    var routedRequest = request
    routedRequest.parsedRootFields = roots

    if !registryRoots.isEmpty {
      switch await workflowRegistry.authorizeForPreflight(routedRequest, rootFields: registryRoots) {
      case let .authorized(principal):
        routedRequest.verifiedRegistryPrincipal = principal
      case let .rejected(error):
        return error
      }
    }
    if !fallbackRoots.isEmpty {
      guard let preflighting = fallback as? any GraphQLDocumentDomainPreflighting else {
        return graphQLError(
          code: WorkflowRegistryErrorCode.forbidden.rawValue,
          message: "mixed-domain fallback does not support preflight"
        )
      }
      var credentialFreeRequest = routedRequest
      credentialFreeRequest.transportCredential = nil
      if let error = await preflighting.preflight(credentialFreeRequest, rootFields: fallbackRoots) {
        return error
      }
    }
    routedRequest.domainPreflightComplete = true
    routedRequest.transportCredential = nil
    var combinedData: JSONObject = [:]
    for root in roots {
      var singleRootRequest = routedRequest
      singleRootRequest.parsedRootFields = [root]
      let isRegistryRoot = WorkflowRegistryGraphQLDocumentExecutor.queryFields.contains(root.fieldName)
        || WorkflowRegistryGraphQLDocumentExecutor.mutationFields.contains(root.fieldName)
      let response = isRegistryRoot
        ? await workflowRegistry.execute(singleRootRequest)
        : await fallback.execute(singleRootRequest)
      guard response.handled else {
        return graphQLError(
          code: WorkflowRegistryErrorCode.invalidWorkflow.rawValue,
          message: "selected GraphQL root was not handled"
        )
      }
      if case let .object(data)? = response.body["data"] {
        combinedData.merge(data) { _, latest in latest }
      }
      if let errors = response.body["errors"] {
        return GraphQLDocumentExecutionResponse(
          handled: true,
          body: [
            "data": combinedData.isEmpty ? .null : .object(combinedData),
            "errors": errors
          ]
        )
      }
    }
    return GraphQLDocumentExecutionResponse(
      handled: true,
      body: ["data": .object(combinedData)]
    )
  }

  private func preflightUnselectedOperations(
    _ operations: [ParsedNoteGraphQLOperation],
    request: GraphQLDocumentRequest
  ) async -> GraphQLDocumentExecutionResponse? {
    for operation in operations {
      do {
        try validateUniqueGraphQLRootResponseKeys(operation.rootFields)
        let registryRoots = operation.rootFields.filter {
          WorkflowRegistryGraphQLDocumentExecutor.queryFields.contains($0.fieldName)
            || WorkflowRegistryGraphQLDocumentExecutor.mutationFields.contains($0.fieldName)
        }
        if !registryRoots.isEmpty {
          try WorkflowRegistryGraphQLDocumentExecutor.validateDocumentRootFields(registryRoots)
        }
        let fallbackRoots = operation.rootFields.filter {
          !WorkflowRegistryGraphQLDocumentExecutor.queryFields.contains($0.fieldName)
            && !WorkflowRegistryGraphQLDocumentExecutor.mutationFields.contains($0.fieldName)
        }
        if !fallbackRoots.isEmpty {
          guard let preflighting = fallback as? any GraphQLDocumentDomainPreflighting else {
            return graphQLError(
              code: WorkflowRegistryErrorCode.forbidden.rawValue,
              message: "unselected GraphQL domain does not support preflight"
            )
          }
          var credentialFreeRequest = request
          credentialFreeRequest.transportCredential = nil
          credentialFreeRequest.parsedRootFields = operation.rootFields
          if let error = await preflighting.preflight(
            credentialFreeRequest,
            rootFields: fallbackRoots
          ) {
            return error
          }
        }
      } catch let error as WorkflowRegistryError {
        return graphQLError(code: error.code.rawValue, message: error.message)
      } catch {
        return graphQLError(
          code: WorkflowRegistryErrorCode.invalidWorkflow.rawValue,
          message: "\(error)"
        )
      }
    }
    return nil
  }
}

enum WorkflowRegistryPreflightOutcome: Sendable {
  case authorized(WorkflowRegistryVerifiedPrincipal?)
  case rejected(GraphQLDocumentExecutionResponse)
}

private func registryJSONValue<T: Encodable>(_ value: T) throws -> JSONValue {
  try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
}

func requiredRegistryInput<T: Decodable>(_ key: String, arguments: JSONObject) throws -> T {
  guard let value = arguments[key] else {
    throw WorkflowRegistryError(code: .invalidWorkflow, message: "missing required input '\(key)'")
  }
  return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
}

func optionalRegistryInput<T: Decodable>(_ key: String, arguments: JSONObject) throws -> T? {
  guard let value = arguments[key], value != .null else { return nil }
  return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
}

private func registryFailureValue(
  for root: ParsedNoteGraphQLRootField,
  error: Error
) -> JSONValue {
  let registryError = (error as? WorkflowRegistryError) ?? WorkflowRegistryError(
    code: .invalidWorkflow,
    message: "\(error)"
  )
  let value: JSONValue?
  if root.fieldName == "workflows" {
    value = try? registryJSONValue(GraphQLWorkflowListPayload(workflows: [], errors: [registryError]))
  } else if root.fieldName == "workflow" {
    value = try? registryJSONValue(GraphQLWorkflowQueryPayload(workflow: nil, errors: [registryError]))
  } else {
    value = try? registryJSONValue(GraphQLWorkflowMutationPayload(accepted: false, errors: [registryError]))
  }
  return value ?? .null
}

private func projectRegistryValue(_ value: JSONValue, selections: [ParsedNoteGraphQLSelectionField]) -> JSONValue {
  guard !selections.isEmpty else { return value }
  switch value {
  case let .array(values):
    return .array(values.map { projectRegistryValue($0, selections: selections) })
  case let .object(object):
    var projected: JSONObject = [:]
    for selection in selections {
      if let child = object[selection.fieldName] {
        projected[selection.responseKey] = projectRegistryValue(child, selections: selection.selections)
      }
    }
    return .object(projected)
  default:
    return value
  }
}

private func graphQLError(
  code: String,
  message: String,
  completedData: JSONObject = [:]
) -> GraphQLDocumentExecutionResponse {
  GraphQLDocumentExecutionResponse(
    handled: true,
    body: [
      "data": completedData.isEmpty ? .null : .object(completedData),
      "errors": .array([.object([
        "message": .string(message),
        "extensions": .object(["code": .string(code)])
      ])])
    ]
  )
}
