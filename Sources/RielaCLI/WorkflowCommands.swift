import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RielaAdapters
import RielaAddons
import RielaCore
import RielaGraphQL
import RielaObservability

public struct CLICommandResult: Equatable, Sendable {
  public var exitCode: CLIExitCode
  public var stdout: String
  public var stderr: String

  public init(exitCode: CLIExitCode, stdout: String = "", stderr: String = "") {
    self.exitCode = exitCode
    self.stdout = stdout
    self.stderr = stderr
  }
}

public struct NodeValidationResult: Codable, Equatable, Sendable {
  public var nodeId: String
  public var backend: String?
  public var valid: Bool
  public var message: String

  public init(nodeId: String, backend: String?, valid: Bool, message: String) {
    self.nodeId = nodeId
    self.backend = backend
    self.valid = valid
    self.message = message
  }
}

public protocol WorkflowExecutablePreflighting: Sendable {
  func preflight(
    _ workflow: WorkflowDefinition,
    nodePayloads: [String: AgentNodePayload],
    packageManifest: WorkflowPackageManifest?,
    sourceScope: WorkflowScope
  ) async throws -> [NodeValidationResult]
}

public struct DeterministicWorkflowExecutablePreflight: WorkflowExecutablePreflighting {
  public init() {}

  public func preflight(
    _ workflow: WorkflowDefinition,
    nodePayloads: [String: AgentNodePayload],
    packageManifest: WorkflowPackageManifest?,
    sourceScope: WorkflowScope
  ) async throws -> [NodeValidationResult] {
    let nativeInspections = nativeBundleAddonInspections(
      workflow: workflow,
      packageManifest: packageManifest,
      sourceScope: sourceScope
    )
    return workflow.nodeRegistry.map { node in
      let payload = nodePayloads[node.id]
      let backend = payload?.executionBackend?.rawValue
      let nativeInspection = nativeInspections.first { $0.nodeId == node.id }
      let valid = payload != nil
      let message: String
      if valid {
        message = "deterministic Swift preflight passed"
      } else if let nativeInspection {
        message = "native-bundle executable preflight helper unavailable for \(nativeInspection.addon); signing=\(nativeInspection.signingRequired ? "required" : "not_required") cache=\(nativeInspection.cacheStatus)"
      } else if node.addon != nil {
        message = "addon-only nodes require an add-on resolver for Swift deterministic execution"
      } else {
        message = "node payload is not loadable"
      }
      return NodeValidationResult(
        nodeId: node.id,
        backend: backend,
        valid: valid,
        message: message
      )
    }
  }
}

public enum WorkflowSourceKind: String, Codable, Equatable, Sendable {
  case workflow
  case package
}

public struct WorkflowValidationCommandResult: Codable, Equatable, Sendable {
  public var valid: Bool
  public var workflowId: String
  public var sourceScope: WorkflowScope
  public var sourceKind: WorkflowSourceKind
  public var workflowDirectory: String
  public var packageName: String?
  public var packageVersion: String?
  public var packageDirectory: String?
  public var mutable: Bool
  @CodableDefaultFalse public var temporary: Bool
  public var diagnostics: [WorkflowValidationDiagnostic]
  public var nodeValidationResults: [NodeValidationResult]

  public init(
    valid: Bool,
    workflowId: String,
    sourceScope: WorkflowScope,
    sourceKind: WorkflowSourceKind = .workflow,
    workflowDirectory: String,
    packageName: String? = nil,
    packageVersion: String? = nil,
    packageDirectory: String? = nil,
    mutable: Bool = true,
    temporary: Bool = false,
    diagnostics: [WorkflowValidationDiagnostic],
    nodeValidationResults: [NodeValidationResult]
  ) {
    self.valid = valid
    self.workflowId = workflowId
    self.sourceScope = sourceScope
    self.sourceKind = sourceKind
    self.workflowDirectory = workflowDirectory
    self.packageName = packageName
    self.packageVersion = packageVersion
    self.packageDirectory = packageDirectory
    self.mutable = mutable
    self.temporary = temporary
    self.diagnostics = diagnostics
    self.nodeValidationResults = nodeValidationResults
  }
}

public struct WorkflowValidationFailureResult: Codable, Equatable, Sendable {
  public var valid: Bool
  public var workflowId: String
  public var sourceScope: WorkflowScope?
  public var workflowDirectory: String?
  public var diagnostics: [WorkflowValidationDiagnostic]
  public var nodeValidationResults: [NodeValidationResult]
  public var error: String
  public var exitCode: Int32

  public init(
    workflowId: String,
    sourceScope: WorkflowScope? = nil,
    workflowDirectory: String? = nil,
    diagnostics: [WorkflowValidationDiagnostic] = [],
    nodeValidationResults: [NodeValidationResult] = [],
    error: String,
    exitCode: Int32
  ) {
    self.valid = false
    self.workflowId = workflowId
    self.sourceScope = sourceScope
    self.workflowDirectory = workflowDirectory
    self.diagnostics = diagnostics
    self.nodeValidationResults = nodeValidationResults
    self.error = error
    self.exitCode = exitCode
  }
}

public struct WorkflowRunFailureResult: Codable, Equatable, Sendable {
  public var workflowId: String?
  public var target: String
  public var status: WorkflowSessionStatus
  public var exitCode: Int32
  public var error: String
  public var sessionId: String?
  public var sessionStore: String?
  public var persistedSession: Bool?
  public var failureKind: WorkflowSessionFailureKind?
  public var stepBudgetDiagnostic: WorkflowStepBudgetDiagnostic?
  public var diagnostics: [String]?
  public var childExitCode: Int32?
  public var terminationSignal: Int32?

  public init(
    workflowId: String? = nil,
    target: String,
    status: WorkflowSessionStatus = .failed,
    exitCode: Int32,
    error: String,
    sessionId: String? = nil,
    sessionStore: String? = nil,
    persistedSession: Bool? = nil,
    failureKind: WorkflowSessionFailureKind? = nil,
    stepBudgetDiagnostic: WorkflowStepBudgetDiagnostic? = nil,
    diagnostics: [String]? = nil,
    childExitCode: Int32? = nil,
    terminationSignal: Int32? = nil
  ) {
    self.workflowId = workflowId
    self.target = target
    self.status = status
    self.exitCode = exitCode
    self.error = error
    self.sessionId = sessionId
    self.sessionStore = sessionStore
    self.persistedSession = persistedSession
    self.failureKind = failureKind
    self.stepBudgetDiagnostic = stepBudgetDiagnostic
    self.diagnostics = diagnostics
    self.childExitCode = childExitCode
    self.terminationSignal = terminationSignal
  }
}

public typealias WorkflowJSONLRecordWriting = @Sendable (String) -> Void

public struct WorkflowRunResultRecord: Codable, Equatable, Sendable {
  public var type: String
  public var result: WorkflowRunResult

  public init(type: String = "run_result", result: WorkflowRunResult) {
    self.type = type
    self.result = result
  }
}

public struct WorkflowRunContextRecord: Codable, Equatable, Sendable {
  public var type: String
  public var sessionId: String
  public var workflowName: String
  public var sessionStore: String
  public var scope: WorkflowScope
  public var artifactRoot: String?

  public init(
    type: String = "run_context",
    sessionId: String,
    workflowName: String,
    sessionStore: String,
    scope: WorkflowScope,
    artifactRoot: String? = nil
  ) {
    self.type = type
    self.sessionId = sessionId
    self.workflowName = workflowName
    self.sessionStore = sessionStore
    self.scope = scope
    self.artifactRoot = artifactRoot
  }
}

public struct WorkflowRemoteRunResultRecord: Codable, Equatable, Sendable {
  public var type: String
  public var result: WorkflowRemoteRunResult

  public init(type: String = "run_result", result: WorkflowRemoteRunResult) {
    self.type = type
    self.result = result
  }
}

public struct WorkflowRemoteRunRequest: Codable, Equatable, Sendable {
  public var workflowName: String
  public var instanceIdentity: String?
  public var runtimeVariables: JSONObject
  public var nodePatch: JSONObject?
  public var autoImprove: Bool
  public var autoImprovePolicy: WorkflowAutoImprovePolicy
  public var maxSteps: Int?
  public var maxConcurrency: Int?
  public var maxLoopIterations: Int?
  public var defaultTimeoutMs: Int?
  public var timeoutMs: Int?
  public var authToken: String?
  public var authTokenEnv: String?
  public var managerSessionId: String?

  public init(
    workflowName: String,
    instanceIdentity: String? = nil,
    runtimeVariables: JSONObject = [:],
    nodePatch: JSONObject? = nil,
    autoImprove: Bool = false,
    autoImprovePolicy: WorkflowAutoImprovePolicy = WorkflowAutoImprovePolicy(),
    maxSteps: Int? = nil,
    maxConcurrency: Int? = nil,
    maxLoopIterations: Int? = nil,
    defaultTimeoutMs: Int? = nil,
    timeoutMs: Int? = nil,
    authToken: String? = nil,
    authTokenEnv: String? = nil,
    managerSessionId: String? = nil
  ) {
    self.workflowName = workflowName
    self.instanceIdentity = instanceIdentity
    self.runtimeVariables = runtimeVariables
    self.nodePatch = nodePatch
    self.autoImprove = autoImprove
    self.autoImprovePolicy = autoImprovePolicy
    self.maxSteps = maxSteps
    self.maxConcurrency = maxConcurrency
    self.maxLoopIterations = maxLoopIterations
    self.defaultTimeoutMs = defaultTimeoutMs
    self.timeoutMs = timeoutMs
    self.authToken = authToken
    self.authTokenEnv = authTokenEnv
    self.managerSessionId = managerSessionId
  }
}

public struct WorkflowRemoteRunResult: Codable, Equatable, Sendable {
  public var sessionId: String
  public var status: String
  public var workflowName: String
  public var workflowId: String
  public var nodeExecutions: Int
  public var transitions: Int
  public var exitCode: Int32

  public init(
    sessionId: String,
    status: String,
    workflowName: String,
    workflowId: String,
    nodeExecutions: Int,
    transitions: Int,
    exitCode: Int32
  ) {
    self.sessionId = sessionId
    self.status = status
    self.workflowName = workflowName
    self.workflowId = workflowId
    self.nodeExecutions = nodeExecutions
    self.transitions = transitions
    self.exitCode = exitCode
  }
}

public struct WorkflowRunPersistenceFailureRecord: Codable, Equatable, Sendable {
  public var type: String
  public var sessionId: String
  public var error: String

  public init(type: String = "session_persist_failed", sessionId: String, error: String) {
    self.type = type
    self.sessionId = sessionId
    self.error = error
  }
}

actor WorkflowRunJSONLRecorder {
  private var lines: [String] = []
  private let writer: WorkflowJSONLRecordWriting?

  init(writer: WorkflowJSONLRecordWriting?) {
    self.writer = writer
  }

  func append(_ event: WorkflowRunEvent) {
    append((try? jsonString(event)) ?? #"{"type":"event_encode_failed"}"# + "\n")
  }

  func append(_ line: String) {
    if let writer {
      writer(line)
    } else {
      lines.append(line)
    }
  }

  func bufferedOutput() -> String {
    writer == nil ? lines.joined() : ""
  }
}

public protocol WorkflowGraphQLRunTransporting: Sendable {
  func executeWorkflow(endpoint: String, request: WorkflowRemoteRunRequest) async throws -> WorkflowRemoteRunResult
}

public struct URLSessionWorkflowGraphQLRunTransport: WorkflowGraphQLRunTransporting {
  public init() {}

  public func executeWorkflow(endpoint: String, request: WorkflowRemoteRunRequest) async throws -> WorkflowRemoteRunResult {
    guard let url = URL(string: endpoint), url.scheme == "http" || url.scheme == "https" else {
      throw CLIUsageError("invalid --endpoint value '\(endpoint)'; expected http or https URL")
    }
    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let authToken = nonEmptyString(request.authToken) {
      urlRequest.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
    }
    if let managerSessionId = nonEmptyString(request.managerSessionId) {
      urlRequest.setValue(managerSessionId, forHTTPHeaderField: "X-Riela-Manager-Session-Id")
    }
    let traceContext = RielaTraceContext.fromEnvironment(CLIRuntimeEnvironment.mergedProcessEnvironment()) ?? .generated()
    for (header, value) in traceContext.environmentValues() {
      urlRequest.setValue(value, forHTTPHeaderField: header)
    }
    let input = remoteRunInputObject(request)
    let graphQLRequest = GraphQLRequest(
      query: """
      mutation ExecuteWorkflow($input: ExecuteWorkflowInput!) {
        executeWorkflow(input: $input) {
          workflowExecutionId
          sessionId
          status
          exitCode
        }
      }
      """,
      variables: ["input": .object(input)]
    )
    let executeData = try await executeGraphQL(urlRequest: urlRequest, request: graphQLRequest)
    let execution = try remoteExecutionPayload(from: executeData, field: "executeWorkflow")
    let summaryRequest = GraphQLRequest(
      query: """
      query WorkflowExecutionSummary($workflowExecutionId: String!) {
        workflowExecution(workflowExecutionId: $workflowExecutionId) {
          session {
            sessionId
            workflowName
            workflowId
            transitions {
              when
            }
          }
          nodeExecutions {
            nodeExecId
          }
        }
      }
      """,
      variables: ["workflowExecutionId": .string(execution.workflowExecutionId)]
    )
    let summaryData = try await executeGraphQL(urlRequest: urlRequest, request: summaryRequest)
    let summary = try remoteWorkflowRunSummary(from: summaryData)
    return WorkflowRemoteRunResult(
      sessionId: execution.sessionId,
      status: execution.status,
      workflowName: summary.workflowName,
      workflowId: summary.workflowId,
      nodeExecutions: summary.nodeExecutions,
      transitions: summary.transitions,
      exitCode: execution.exitCode
    )
  }

  private func executeGraphQL(urlRequest: URLRequest, request: GraphQLRequest) async throws -> JSONObject {
    var postRequest = urlRequest
    postRequest.httpBody = try JSONEncoder().encode(request)
    let (data, response) = try await URLSession.shared.data(for: postRequest)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw CLIUsageError("remote run failed with HTTP \(http.statusCode)")
    }
    let envelope = try JSONDecoder().decode(JSONValue.self, from: data)
    guard case let .object(root) = envelope else {
      throw CLIUsageError("remote run returned non-object GraphQL response")
    }
    if case let .array(errors)? = root["errors"], !errors.isEmpty {
      throw CLIUsageError("remote run returned GraphQL errors")
    }
    guard
      case let .object(dataObject)? = root["data"],
      !dataObject.isEmpty
    else {
      throw CLIUsageError("remote run response missing data payload")
    }
    return dataObject
  }
}

private func remoteRunInputObject(_ request: WorkflowRemoteRunRequest) -> JSONObject {
  var input: JSONObject = [
    "workflowName": .string(request.workflowName),
    "runtimeVariables": .object(request.runtimeVariables)
  ]
  if let instanceIdentity = request.instanceIdentity {
    input["instanceIdentity"] = .string(instanceIdentity)
  }
  if request.autoImprove {
    input["autoImprove"] = .object(remoteAutoImprovePolicyInput(request.autoImprovePolicy))
  }
  if let nodePatch = request.nodePatch {
    input["nodePatch"] = .object(nodePatch)
  }
  if let maxSteps = request.maxSteps {
    input["maxSteps"] = .number(Double(maxSteps))
  }
  if let maxConcurrency = request.maxConcurrency {
    input["maxConcurrency"] = .number(Double(maxConcurrency))
  }
  if let maxLoopIterations = request.maxLoopIterations {
    input["maxLoopIterations"] = .number(Double(maxLoopIterations))
  }
  if let defaultTimeoutMs = request.defaultTimeoutMs {
    input["defaultTimeoutMs"] = .number(Double(defaultTimeoutMs))
  }
  if request.autoImprove && request.autoImprovePolicy.nestedSuperviser {
    input["nestedSuperviser"] = .bool(true)
  }
  return input
}

func nonEmptyString(_ value: String?) -> String? {
  guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
    return nil
  }
  return value
}

private func remoteAutoImprovePolicyInput(_ policy: WorkflowAutoImprovePolicy) -> JSONObject {
  var input: JSONObject = [
    "enabled": .bool(true),
    "maxSupervisedAttempts": .number(Double(policy.maxSupervisedAttempts)),
    "maxWorkflowPatches": .number(Double(policy.maxWorkflowPatches)),
    "monitorIntervalMs": .number(Double(policy.monitorIntervalMs)),
    "stallTimeoutMs": .number(Double(policy.stallTimeoutMs)),
    "stallDetectionEnabled": .bool(policy.stallDetectionEnabled)
  ]
  if policy.workflowMutationMode.isForwardedToRemoteExecution {
    input["workflowMutationMode"] = .string(policy.workflowMutationMode.rawValue)
  }
  return input
}

private struct RemoteExecutionPayload {
  var workflowExecutionId: String
  var sessionId: String
  var status: String
  var exitCode: Int32
}

private struct RemoteWorkflowRunSummary {
  var workflowName: String
  var workflowId: String
  var nodeExecutions: Int
  var transitions: Int
}

private func remoteExecutionPayload(from data: JSONObject, field: String) throws -> RemoteExecutionPayload {
  guard case let .object(payload)? = data[field] else {
    throw CLIUsageError("remote run response missing \(field) payload")
  }
  let workflowExecutionId = try requiredString(payload["workflowExecutionId"], field: "\(field).workflowExecutionId")
  let sessionId = try requiredString(payload["sessionId"], field: "\(field).sessionId")
  let status = try requiredString(payload["status"], field: "\(field).status")
  let exitCode = try Int32(requiredInt(payload["exitCode"], field: "\(field).exitCode"))
  return RemoteExecutionPayload(
    workflowExecutionId: workflowExecutionId,
    sessionId: sessionId,
    status: status,
    exitCode: exitCode
  )
}

private func remoteWorkflowRunSummary(from data: JSONObject) throws -> RemoteWorkflowRunSummary {
  guard
    case let .object(workflowExecution)? = data["workflowExecution"],
    case let .object(session)? = workflowExecution["session"]
  else {
    throw CLIUsageError("remote run response missing workflowExecution summary")
  }
  return try RemoteWorkflowRunSummary(
    workflowName: requiredString(session["workflowName"], field: "workflowExecution.session.workflowName"),
    workflowId: requiredString(session["workflowId"], field: "workflowExecution.session.workflowId"),
    nodeExecutions: requiredArrayCount(workflowExecution["nodeExecutions"], field: "workflowExecution.nodeExecutions"),
    transitions: requiredArrayCount(session["transitions"], field: "workflowExecution.session.transitions")
  )
}

private func requiredString(_ value: JSONValue?, field: String) throws -> String {
  guard case let .string(string)? = value, !string.isEmpty else {
    throw CLIUsageError("\(field) is missing or not a string")
  }
  return string
}

private func requiredInt(_ value: JSONValue?, field: String) throws -> Int {
  guard let int64 = value?.asInt64, let value = Int(exactly: int64) else {
    throw CLIUsageError("\(field) is missing or not a number")
  }
  return value
}

private func requiredArrayCount(_ value: JSONValue?, field: String) throws -> Int {
  guard case let .array(array)? = value else {
    throw CLIUsageError("\(field) is missing or not an array")
  }
  return array.count
}
