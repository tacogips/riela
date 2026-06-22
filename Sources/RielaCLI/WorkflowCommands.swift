// swiftlint:disable file_length
// CLI workflow commands aggregate parser-facing result models and command runners in one production entrypoint.
// Splitting it requires target-boundary edits outside this worker group's owned file, so the file_length rule is not actionable here.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RielaAdapters
import RielaAddons
import RielaCore
import RielaGraphQL

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

  public init(
    workflowId: String? = nil,
    target: String,
    status: WorkflowSessionStatus = .failed,
    exitCode: Int32,
    error: String
  ) {
    self.workflowId = workflowId
    self.target = target
    self.status = status
    self.exitCode = exitCode
    self.error = error
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

private actor WorkflowRunJSONLRecorder {
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

private func nonEmptyString(_ value: String?) -> String? {
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
    "stallTimeoutMs": .number(Double(policy.stallTimeoutMs))
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
  guard case let .number(number)? = value else {
    throw CLIUsageError("\(field) is missing or not a number")
  }
  return Int(number)
}

private func requiredArrayCount(_ value: JSONValue?, field: String) throws -> Int {
  guard case let .array(array)? = value else {
    throw CLIUsageError("\(field) is missing or not an array")
  }
  return array.count
}

public struct WorkflowManifestValidationCommandResult: Codable, Equatable, Sendable {
  public var manifestPath: String
  public var valid: Bool
  public var issues: [WorkflowPackageValidationIssue]
  public var executablePreflight: Bool
}

public struct WorkflowCatalogEntry: Codable, Equatable, Sendable {
  public var workflowName: String
  public var scope: WorkflowScope
  public var sourceKind: WorkflowSourceKind
  public var workflowDirectory: String
  public var packageName: String?
  public var packageVersion: String?
  public var packageDirectory: String?
  public var mutable: Bool
  public var valid: Bool
  public var diagnostics: [WorkflowValidationDiagnostic]

  public init(
    workflowName: String,
    scope: WorkflowScope,
    sourceKind: WorkflowSourceKind = .workflow,
    workflowDirectory: String,
    packageName: String? = nil,
    packageVersion: String? = nil,
    packageDirectory: String? = nil,
    mutable: Bool = true,
    valid: Bool,
    diagnostics: [WorkflowValidationDiagnostic]
  ) {
    self.workflowName = workflowName
    self.scope = scope
    self.sourceKind = sourceKind
    self.workflowDirectory = workflowDirectory
    self.packageName = packageName
    self.packageVersion = packageVersion
    self.packageDirectory = packageDirectory
    self.mutable = mutable
    self.valid = valid
    self.diagnostics = diagnostics
  }
}

public struct WorkflowCatalogResult: Codable, Equatable, Sendable {
  public var workflows: [WorkflowCatalogEntry]
}

private func workflowSourceKind(_ bundle: ResolvedWorkflowBundle) -> WorkflowSourceKind {
  bundle.packageManifest == nil ? .workflow : .package
}

public struct WorkflowManifestValidateCommand: Sendable {
  public var loader: any WorkflowPackageManifestLoading

  public init(loader: any WorkflowPackageManifestLoading = FileWorkflowPackageManifestLoader()) {
    self.loader = loader
  }

  public func run(_ options: WorkflowManifestValidateOptions) async -> CLICommandResult {
    do {
      let workingDirectory = URL(fileURLWithPath: options.workingDirectory, isDirectory: true)
      let manifestURL = absoluteURL(options.manifestPath, relativeTo: workingDirectory)
      let manifest = try await loader.loadManifest(from: manifestURL)
      let issues = await loader.validate(manifest, packageRoot: manifestURL.deletingLastPathComponent())
      let result = WorkflowManifestValidationCommandResult(
        manifestPath: manifestURL.path,
        valid: issues.isEmpty,
        issues: issues,
        executablePreflight: options.executable
      )
      return CLICommandResult(
        exitCode: result.valid ? .success : .usage,
        stdout: try render(result, output: options.output)
      )
    } catch {
      if options.output.isStructured {
        let result = WorkflowManifestValidationCommandResult(
          manifestPath: options.manifestPath,
          valid: false,
          issues: [
            WorkflowPackageValidationIssue(
              code: "INVALID_MANIFEST",
              path: options.manifestPath,
              message: "\(error)"
            )
          ],
          executablePreflight: options.executable
        )
        return CLICommandResult(exitCode: .failure, stdout: (try? jsonString(result)) ?? "")
      }
      return CLICommandResult(exitCode: .failure, stderr: "workflow manifest validation failed: \(error)")
    }
  }

  private func render(_ result: WorkflowManifestValidationCommandResult, output: WorkflowOutputFormat) throws -> String {
    switch output {
    case .json, .jsonl:
      return try jsonString(result)
    case .text, .table:
      var lines = [
        result.valid ? "valid: \(result.manifestPath)" : "invalid: \(result.manifestPath)"
      ]
      lines.append(contentsOf: result.issues.map { "\($0.code): \($0.path): \($0.message)" })
      return lines.joined(separator: "\n") + "\n"
    }
  }
}

public struct WorkflowCatalogCommand: Sendable {
  public init() {}

  public func list(_ options: CLICommandOptions) -> CLICommandResult {
    do {
      let entries = try catalogEntries(options: options)
      return CLICommandResult(exitCode: .success, stdout: try render(WorkflowCatalogResult(workflows: entries), output: options.output))
    } catch let error as CLIUsageError {
      return CLICommandResult(exitCode: .usage, stderr: error.message)
    } catch {
      return CLICommandResult(exitCode: .failure, stderr: "\(error)")
    }
  }

  public func status(_ options: CLICommandOptions) -> CLICommandResult {
    guard let target = options.target, !target.isEmpty else {
      return CLICommandResult(exitCode: .usage, stderr: "workflow name is required for workflow status")
    }
    do {
      let parsed = try catalogParseOptions(options)
      let resolution = WorkflowResolutionOptions(
        workflowName: target,
        scope: parsed.scope,
        workflowDefinitionDir: nil,
        workingDirectory: parsed.workingDirectory
      )
      let bundle = try FileSystemWorkflowBundleResolver().resolve(resolution)
      let diagnostics = bundle.diagnostics + DefaultWorkflowValidator().validate(bundle.workflow)
      let entry = WorkflowCatalogEntry(
        workflowName: target,
        scope: bundle.sourceScope,
        sourceKind: workflowSourceKind(bundle),
        workflowDirectory: bundle.workflowDirectory,
        packageName: bundle.packageManifest?.name,
        packageVersion: bundle.packageManifest?.version,
        packageDirectory: bundle.packageDirectory,
        mutable: bundle.packageManifest == nil,
        valid: !diagnostics.contains { $0.severity == .error },
        diagnostics: diagnostics
      )
      return CLICommandResult(
        exitCode: entry.valid ? .success : .failure,
        stdout: try render(WorkflowCatalogResult(workflows: [entry]), output: options.output)
      )
    } catch let error as CLIUsageError {
      return CLICommandResult(exitCode: .usage, stderr: error.message)
    } catch {
      return CLICommandResult(exitCode: .failure, stderr: "\(error)")
    }
  }

  private struct ParsedCatalogOptions {
    var scope: WorkflowScope
    var workingDirectory: String
  }

  private func catalogEntries(options: CLICommandOptions) throws -> [WorkflowCatalogEntry] {
    let parsed = try catalogParseOptions(options)
    let roots = workflowRoots(scope: parsed.scope, workingDirectory: parsed.workingDirectory)
    var entries: [WorkflowCatalogEntry] = []
    for (scope, root) in roots {
      let names = try workflowNames(in: root)
      for name in names {
        let resolution = WorkflowResolutionOptions(workflowName: name, scope: scope, workingDirectory: parsed.workingDirectory)
        do {
          let bundle = try FileSystemWorkflowBundleResolver().resolve(resolution)
          let diagnostics = bundle.diagnostics + DefaultWorkflowValidator().validate(bundle.workflow)
          entries.append(WorkflowCatalogEntry(
            workflowName: name,
            scope: bundle.sourceScope,
            sourceKind: workflowSourceKind(bundle),
            workflowDirectory: bundle.workflowDirectory,
            packageName: bundle.packageManifest?.name,
            packageVersion: bundle.packageManifest?.version,
            packageDirectory: bundle.packageDirectory,
            mutable: bundle.packageManifest == nil,
            valid: !diagnostics.contains { $0.severity == .error },
            diagnostics: diagnostics
          ))
        } catch {
          entries.append(WorkflowCatalogEntry(
            workflowName: name,
            scope: scope,
            sourceKind: .workflow,
            workflowDirectory: root.appendingPathComponent(name).path,
            mutable: true,
            valid: false,
            diagnostics: [
              WorkflowValidationDiagnostic(severity: .error, path: "workflow.json", message: "\(error)")
            ]
          ))
        }
      }
    }
    entries.append(contentsOf: try packageCatalogEntries(options: parsed))
    return entries.sorted { left, right in
      if left.scope.rawValue != right.scope.rawValue {
        return left.scope.rawValue < right.scope.rawValue
      }
      if left.workflowName != right.workflowName {
        return left.workflowName < right.workflowName
      }
      return left.sourceKind.rawValue < right.sourceKind.rawValue
    }
  }

  private func packageCatalogEntries(options: ParsedCatalogOptions) throws -> [WorkflowCatalogEntry] {
    var entries: [WorkflowCatalogEntry] = []
    for (scope, root) in packageRoots(scope: options.scope, workingDirectory: options.workingDirectory) {
      guard FileManager.default.fileExists(atPath: root.path) else {
        continue
      }
      for manifestURL in try packageManifestURLs(in: root) {
        let packageDirectory = manifestURL.deletingLastPathComponent().standardizedFileURL
        do {
          let manifest = try JSONDecoder().decode(WorkflowPackageManifest.self, from: Data(contentsOf: manifestURL))
          guard manifest.kind == .workflow else {
            continue
          }
          let issues = WorkflowPackageManifestValidator.validate(manifest)
            + WorkflowPackageManifestValidator.validateWorkflowBundle(manifest, packageRoot: packageDirectory)
          let workflowDirectory: URL
          if let normalized = WorkflowPackageManifestValidator.normalizePackageRelativePath(manifest.workflowDirectory ?? ".") {
            workflowDirectory = packageDirectory.appendingPathComponent(normalized, isDirectory: true).standardizedFileURL
          } else {
            workflowDirectory = packageDirectory
          }
          let diagnostics = issues.map {
            WorkflowValidationDiagnostic(severity: .error, path: $0.path, message: $0.message)
          }
          entries.append(WorkflowCatalogEntry(
            workflowName: manifest.name,
            scope: scope,
            sourceKind: .package,
            workflowDirectory: workflowDirectory.path,
            packageName: manifest.name,
            packageVersion: manifest.version,
            packageDirectory: packageDirectory.path,
            mutable: false,
            valid: diagnostics.isEmpty,
            diagnostics: diagnostics
          ))
        } catch {
          entries.append(WorkflowCatalogEntry(
            workflowName: packageDirectoryRelativeName(packageDirectory, packageRoot: root),
            scope: scope,
            sourceKind: .package,
            workflowDirectory: packageDirectory.path,
            packageDirectory: packageDirectory.path,
            mutable: false,
            valid: false,
            diagnostics: [
              WorkflowValidationDiagnostic(severity: .error, path: "riela-package.json", message: "\(error)")
            ]
          ))
        }
      }
    }
    return entries
  }

  private func render(_ result: WorkflowCatalogResult, output: WorkflowOutputFormat) throws -> String {
    switch output {
    case .json, .jsonl:
      return try jsonString(result)
    case .text:
      return result.workflows.map {
        "\($0.workflowName)\t\($0.scope.rawValue)\t\($0.sourceKind.rawValue)\t\($0.valid ? "valid" : "invalid")\t\($0.workflowDirectory)"
      }.joined(separator: "\n") + (result.workflows.isEmpty ? "" : "\n")
    case .table:
      let header = "WORKFLOW\tSCOPE\tSOURCE\tSTATUS\tDIRECTORY"
      let rows = result.workflows.map {
        "\($0.workflowName)\t\($0.scope.rawValue)\t\($0.sourceKind.rawValue)\t\($0.valid ? "valid" : "invalid")\t\($0.workflowDirectory)"
      }
      return ([header] + rows).joined(separator: "\n") + "\n"
    }
  }

  private func catalogParseOptions(_ options: CLICommandOptions) throws -> ParsedCatalogOptions {
    var scope = WorkflowScope.auto
    var workingDirectory = FileManager.default.currentDirectoryPath
    var index = 0
    while index < options.arguments.count {
      let token = options.arguments[index]
      switch token {
      case "--scope":
        guard index + 1 < options.arguments.count, let value = WorkflowScope(rawValue: options.arguments[index + 1]), value != .direct else {
          throw CLIUsageError("invalid --scope value; expected auto, project, or user")
        }
        scope = value
        index += 2
      case "--working-dir", "--working-directory":
        guard index + 1 < options.arguments.count else {
          throw CLIUsageError("\(token) requires a value")
        }
        workingDirectory = options.arguments[index + 1]
        index += 2
      case "--output":
        index += 2
      default:
        if token.hasPrefix("--output=") {
          index += 1
        } else {
          throw CLIUsageError("unsupported workflow catalog option '\(token)'")
        }
      }
    }
    return ParsedCatalogOptions(scope: scope, workingDirectory: workingDirectory)
  }

  private func workflowRoots(scope: WorkflowScope, workingDirectory: String) -> [(WorkflowScope, URL)] {
    let project = URL(fileURLWithPath: workingDirectory).appendingPathComponent(".riela/workflows", isDirectory: true)
    let user = URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory()).appendingPathComponent(".riela/workflows", isDirectory: true)
    switch scope {
    case .project:
      return [(.project, project)]
    case .user:
      return [(.user, user)]
    case .auto, .direct:
      return [(.project, project), (.user, user)]
    }
  }

  private func workflowNames(in root: URL) throws -> [String] {
    guard FileManager.default.fileExists(atPath: root.path) else {
      return []
    }
    let contents = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
    return contents.compactMap { url in
      guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
        return nil
      }
      return url.lastPathComponent
    }
  }

  private func packageRoots(scope: WorkflowScope, workingDirectory: String) -> [(WorkflowScope, URL)] {
    let project = URL(fileURLWithPath: workingDirectory).appendingPathComponent(".riela/packages", isDirectory: true)
    let user = URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory()).appendingPathComponent(".riela/packages", isDirectory: true)
    switch scope {
    case .project:
      return [(.project, project)]
    case .user:
      return [(.user, user)]
    case .auto, .direct:
      return [(.project, project), (.user, user)]
    }
  }

  private func packageManifestURLs(in root: URL) throws -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) else {
      return []
    }
    var urls: [URL] = []
    for case let url as URL in enumerator where url.lastPathComponent == "riela-package.json" {
      urls.append(url)
      enumerator.skipDescendants()
    }
    return urls.sorted { $0.path < $1.path }
  }

  private func packageDirectoryRelativeName(_ packageDirectory: URL, packageRoot: URL) -> String {
    let packagePath = packageDirectory.standardizedFileURL.path
    let rootPath = packageRoot.standardizedFileURL.path
    guard packagePath.hasPrefix(rootPath + "/") else {
      return packageDirectory.lastPathComponent
    }
    return String(packagePath.dropFirst(rootPath.count + 1))
  }
}

public struct WorkflowValidateCommand: Sendable {
  public var resolver: any WorkflowBundleResolving
  public var patchApplier: any WorkflowNodePatchApplying
  public var jsonLoader: JSONReferenceLoader
  public var preflight: any WorkflowExecutablePreflighting

  public init(
    resolver: any WorkflowBundleResolving = FileSystemWorkflowBundleResolver(),
    patchApplier: any WorkflowNodePatchApplying = DefaultWorkflowNodePatchApplier(),
    jsonLoader: JSONReferenceLoader = JSONReferenceLoader(),
    preflight: any WorkflowExecutablePreflighting = DeterministicWorkflowExecutablePreflight()
  ) {
    self.resolver = resolver
    self.patchApplier = patchApplier
    self.jsonLoader = jsonLoader
    self.preflight = preflight
  }

  public func run(_ options: WorkflowValidateOptions) async -> CLICommandResult {
    do {
      var bundle = try resolver.resolve(options.resolution)
      if let patch = options.nodePatch {
        bundle.nodePayloads = try patchApplier.applyNodePatch(
          jsonLoader.object(from: patch, workingDirectory: options.resolution.workingDirectory),
          to: bundle.nodePayloads
        )
      }
      let diagnostics = bundle.diagnostics + DefaultWorkflowValidator().validate(bundle.workflow)
      let nodeResults = options.executable
        ? try await preflight.preflight(
          bundle.workflow,
          nodePayloads: bundle.nodePayloads,
          packageManifest: bundle.packageManifest,
          sourceScope: bundle.sourceScope
        )
        : []
      let valid = !diagnostics.contains { $0.severity == .error } && !nodeResults.contains { !$0.valid }
      let result = WorkflowValidationCommandResult(
        valid: valid,
        workflowId: bundle.workflow.workflowId,
        sourceScope: bundle.sourceScope,
        sourceKind: workflowSourceKind(bundle),
        workflowDirectory: bundle.workflowDirectory,
        packageName: bundle.packageManifest?.name,
        packageVersion: bundle.packageManifest?.version,
        packageDirectory: bundle.packageDirectory,
        mutable: bundle.packageManifest == nil,
        diagnostics: diagnostics,
        nodeValidationResults: nodeResults
      )
      return CLICommandResult(
        exitCode: valid ? .success : .failure,
        stdout: try render(result, output: options.output)
      )
    } catch let error as WorkflowResolutionError {
      let diagnostics: [WorkflowValidationDiagnostic]
      if case let .invalidWorkflow(workflowDiagnostics) = error {
        diagnostics = workflowDiagnostics
      } else {
        diagnostics = []
      }
      return renderFailure(
        options: options,
        exitCode: .failure,
        error: "\(error)",
        diagnostics: diagnostics
      )
    } catch let error as CLIUsageError {
      return renderFailure(options: options, exitCode: .usage, error: error.message)
    } catch {
      return renderFailure(options: options, exitCode: .failure, error: "\(error)")
    }
  }

  private func render(_ result: WorkflowValidationCommandResult, output: WorkflowOutputFormat) throws -> String {
    switch output {
    case .json, .jsonl:
      return try jsonString(result)
    case .text, .table:
      var lines = [
        result.valid ? "valid: \(result.workflowId)" : "invalid: \(result.workflowId)",
        "source: \(result.sourceScope.rawValue) \(result.sourceKind.rawValue) \(result.workflowDirectory)"
      ]
      if let packageName = result.packageName {
        lines.append("package: \(packageName) \(result.packageVersion ?? "") \(result.packageDirectory ?? "")")
      }
      lines.append("mutable: \(result.mutable ? "true" : "false")")
      lines.append(contentsOf: result.diagnostics.map { "\($0.severity.rawValue): \($0.path): \($0.message)" })
      lines.append(contentsOf: result.nodeValidationResults.map { "\($0.valid ? "ok" : "error"): \($0.nodeId): \($0.message)" })
      return lines.joined(separator: "\n") + "\n"
    }
  }

  private func renderFailure(
    options: WorkflowValidateOptions,
    exitCode: CLIExitCode,
    error: String,
    diagnostics: [WorkflowValidationDiagnostic] = []
  ) -> CLICommandResult {
    guard options.output.isStructured else {
      return CLICommandResult(exitCode: exitCode, stderr: error)
    }
    let result = WorkflowValidationFailureResult(
      workflowId: options.workflowName,
      sourceScope: options.resolution.scope == .direct ? nil : options.resolution.scope,
      workflowDirectory: options.resolution.workflowDefinitionDir,
      diagnostics: diagnostics,
      error: error,
      exitCode: exitCode.rawValue
    )
    let stdout = (try? jsonString(result)) ?? #"{"diagnostics":[],"error":"failed to encode validate failure","exitCode":1,"nodeValidationResults":[],"valid":false,"workflowId":"workflow validate"}"# + "\n"
    return CLICommandResult(exitCode: exitCode, stdout: stdout)
  }
}

public struct WorkflowInspectionCounts: Codable, Equatable, Sendable {
  public var steps: Int
  public var nodes: Int
  public var crossWorkflowDispatches: Int
}

public struct WorkflowCallableInspection: Codable, Equatable, Sendable {
  public var stepId: String
  public var role: NodeRole
  public var input: NodeInputContract?
  public var output: NodeOutputContract?
}

public struct WorkflowInspectionSummary: Codable, Equatable, Sendable {
  public var workflowId: String
  public var sourceScope: WorkflowScope
  public var sourceKind: WorkflowSourceKind
  public var workflowDirectory: String
  public var packageName: String?
  public var packageVersion: String?
  public var packageDirectory: String?
  public var mutable: Bool
  public var description: String
  public var entryStepId: String
  public var managerStepId: String?
  public var stepIds: [String]
  public var nodeRegistryIds: [String]
  public var crossWorkflowDispatchIds: [String]
  public var counts: WorkflowInspectionCounts
  public var defaults: WorkflowDefaults
  public var callable: WorkflowCallableInspection
  public var addonSourceSummaries: [String]
  public var nativeBundleAddons: [NativeBundleAddonInspection]
  public var runtimeReadinessDescriptors: [String]
}

public struct NativeBundleAddonInspection: Codable, Equatable, Sendable {
  public var nodeId: String
  public var addon: String
  public var sourceKind: String
  public var sourceScope: String
  public var packageName: String?
  public var bundleIdentifier: String
  public var abiVersion: Int
  public var contentDigest: String
  public var dependencyClosureDigest: String
  public var signingRequired: Bool
  public var signingVerified: Bool?
  public var cacheStatus: String
  public var preflightHelperStatus: String?
}

private func nativeBundleAddonInspections(
  workflow: WorkflowDefinition,
  packageManifest: WorkflowPackageManifest?,
  sourceScope: WorkflowScope
) -> [NativeBundleAddonInspection] {
  guard let packageManifest else {
    return []
  }
  let nativeLocks = packageManifest.dependencies.flatMap { dependency in
    dependency.addons.compactMap { lock -> (WorkflowPackageDependency, WorkflowPackageManifestAddonDependencyLock)? in
      lock.executionKind == .nativeBundle ? (dependency, lock) : nil
    }
  }
  guard !nativeLocks.isEmpty else {
    return []
  }

  return workflow.nodeRegistry.compactMap { node in
    guard let addon = node.addon else {
      return nil
    }
    guard let match = nativeLocks.first(where: { dependency, lock in
      let versionMatches = addon.version == nil || lock.version == addon.version
      let nameMatches = lock.name == addon.name || "\(dependency.packageId)/\(lock.name)" == addon.name
      return nameMatches && versionMatches
    }) else {
      return nil
    }
    let dependency = match.0
    let lock = match.1
    return NativeBundleAddonInspection(
      nodeId: node.id,
      addon: addon.name,
      sourceKind: WorkflowPackageAddonExecutionKind.nativeBundle.rawValue,
      sourceScope: lock.sourceScope ?? sourceScope.rawValue,
      packageName: dependency.packageId,
      bundleIdentifier: lock.bundleIdentifier ?? "",
      abiVersion: lock.abiVersion ?? 0,
      contentDigest: lock.contentDigest ?? "",
      dependencyClosureDigest: lock.dependencyClosureDigest ?? "",
      signingRequired: lock.codeSignatureRequirementDigest != nil,
      signingVerified: nil,
      cacheStatus: "not_loaded",
      preflightHelperStatus: nil
    )
  }
}

public struct WorkflowInspectionFailureResult: Codable, Equatable, Sendable {
  public var workflowId: String
  public var sourceScope: WorkflowScope?
  public var workflowDirectory: String?
  public var diagnostics: [WorkflowValidationDiagnostic]
  public var error: String
  public var exitCode: Int32

  public init(
    workflowId: String,
    sourceScope: WorkflowScope? = nil,
    workflowDirectory: String? = nil,
    diagnostics: [WorkflowValidationDiagnostic] = [],
    error: String,
    exitCode: Int32
  ) {
    self.workflowId = workflowId
    self.sourceScope = sourceScope
    self.workflowDirectory = workflowDirectory
    self.diagnostics = diagnostics
    self.error = error
    self.exitCode = exitCode
  }
}

public struct WorkflowInspectCommand: Sendable {
  public var resolver: any WorkflowBundleResolving

  public init(resolver: any WorkflowBundleResolving = FileSystemWorkflowBundleResolver()) {
    self.resolver = resolver
  }

  public func run(_ options: WorkflowInspectOptions) -> CLICommandResult {
    do {
      let bundle = try resolver.resolve(options.resolution)
      let summary = buildSummary(bundle)
      if options.output.isStructured {
        return CLICommandResult(exitCode: .success, stdout: try jsonString(summary))
      }
      if options.structure {
        return CLICommandResult(exitCode: .success, stdout: renderStructure(bundle.workflow))
      }
      return CLICommandResult(exitCode: .success, stdout: renderText(summary))
    } catch let error as WorkflowResolutionError {
      let diagnostics: [WorkflowValidationDiagnostic]
      if case let .invalidWorkflow(workflowDiagnostics) = error {
        diagnostics = workflowDiagnostics
      } else {
        diagnostics = []
      }
      return renderFailure(options: options, exitCode: .failure, error: "\(error)", diagnostics: diagnostics)
    } catch {
      return renderFailure(options: options, exitCode: .failure, error: "\(error)")
    }
  }

  private func buildSummary(_ bundle: ResolvedWorkflowBundle) -> WorkflowInspectionSummary {
    let workflow = bundle.workflow
    let crossWorkflowIds = workflow.steps.flatMap { step in
      (step.transitions ?? []).compactMap { transition in
        transition.toWorkflowId.map { "\(step.id)->\($0):\(transition.toStepId)" }
      }
    }
    let addonSummaries = workflow.nodeRegistry.compactMap { node in
      node.addon.map { "\(node.id):\($0.name)" }
    }
    let nativeBundleAddons = nativeBundleAddonInspections(
      workflow: workflow,
      packageManifest: bundle.packageManifest,
      sourceScope: bundle.sourceScope
    )
    let readiness = workflow.nodeRegistry.map { node -> String in
      guard let payload = bundle.nodePayloads[node.id] else {
        return "\(node.id):not_checked"
      }
      return "\(node.id):\(payload.executionBackend?.rawValue ?? "deterministic-local")"
    }
    let callable = buildCallableInspection(workflow, nodePayloads: bundle.nodePayloads)
    return WorkflowInspectionSummary(
      workflowId: workflow.workflowId,
      sourceScope: bundle.sourceScope,
      sourceKind: workflowSourceKind(bundle),
      workflowDirectory: bundle.workflowDirectory,
      packageName: bundle.packageManifest?.name,
      packageVersion: bundle.packageManifest?.version,
      packageDirectory: bundle.packageDirectory,
      mutable: bundle.packageManifest == nil,
      description: workflow.description,
      entryStepId: workflow.entryStepId,
      managerStepId: workflow.managerStepId,
      stepIds: workflow.steps.map(\.id),
      nodeRegistryIds: workflow.nodeRegistry.map(\.id),
      crossWorkflowDispatchIds: crossWorkflowIds,
      counts: WorkflowInspectionCounts(
        steps: workflow.steps.count,
        nodes: workflow.nodeRegistry.count,
        crossWorkflowDispatches: crossWorkflowIds.count
      ),
      defaults: workflow.defaults,
      callable: callable,
      addonSourceSummaries: addonSummaries,
      nativeBundleAddons: nativeBundleAddons,
      runtimeReadinessDescriptors: readiness
    )
  }

  private func buildCallableInspection(
    _ workflow: WorkflowDefinition,
    nodePayloads: [String: AgentNodePayload]
  ) -> WorkflowCallableInspection {
    let stepId = workflow.managerStepId ?? workflow.entryStepId
    let step = workflow.steps.first { $0.id == stepId }
    let role = step?.role ?? (workflow.managerStepId == stepId ? .manager : .worker)
    let payload = nodePayload(for: step, stepId: stepId, nodePayloads: nodePayloads)
    return WorkflowCallableInspection(
      stepId: stepId,
      role: role,
      input: payload?.input,
      output: payload?.output
    )
  }

  private func nodePayload(
    for step: WorkflowStepRef?,
    stepId: String,
    nodePayloads: [String: AgentNodePayload]
  ) -> AgentNodePayload? {
    if let payload = nodePayloads[stepId] {
      return payload
    }
    if let nodeId = step?.nodeId, let payload = nodePayloads[nodeId] {
      return payload
    }
    return nil
  }

  private func renderStructure(_ workflow: WorkflowDefinition) -> String {
    workflow.steps.map { step in
      "\(step.id)\n  \(step.description ?? "-")"
    }.joined(separator: "\n") + "\n"
  }

  private func renderText(_ summary: WorkflowInspectionSummary) -> String {
    var lines = [
      "workflow: \(summary.workflowId)",
      "source: \(summary.sourceScope.rawValue) \(summary.sourceKind.rawValue) \(summary.workflowDirectory)",
      "entryStepId: \(summary.entryStepId)",
      "steps: \(summary.stepIds.joined(separator: ", "))",
      "nodes: \(summary.nodeRegistryIds.joined(separator: ", "))",
      "counts: steps=\(summary.counts.steps) nodes=\(summary.counts.nodes) crossWorkflowDispatches=\(summary.counts.crossWorkflowDispatches)"
    ]
    if let manager = summary.managerStepId {
      lines.append("managerStepId: \(manager)")
    }
    if let packageName = summary.packageName {
      lines.append("package: \(packageName) \(summary.packageVersion ?? "") \(summary.packageDirectory ?? "")")
    }
    lines.append("mutable: \(summary.mutable ? "true" : "false")")
    lines.append("callableStepId: \(summary.callable.stepId)")
    lines.append("callableRole: \(summary.callable.role.rawValue)")
    if let input = summary.callable.input {
      lines.append("callableInput: \(contractDescription(input.description))")
    }
    if let output = summary.callable.output {
      lines.append("callableOutput: \(contractDescription(output.description))")
    }
    if summary.callable.input != nil {
      lines.append("variables: --variables '{...}'")
    }
    if !summary.addonSourceSummaries.isEmpty {
      lines.append("addons: \(summary.addonSourceSummaries.joined(separator: ", "))")
    }
    if !summary.nativeBundleAddons.isEmpty {
      lines.append(contentsOf: summary.nativeBundleAddons.map {
        "nativeBundle: \($0.nodeId): \($0.addon) \($0.bundleIdentifier) abi=\($0.abiVersion) cache=\($0.cacheStatus)"
      })
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private func contractDescription(_ description: String?) -> String {
    guard let description, !description.isEmpty else {
      return "(not declared)"
    }
    return description
  }

  private func renderFailure(
    options: WorkflowInspectOptions,
    exitCode: CLIExitCode,
    error: String,
    diagnostics: [WorkflowValidationDiagnostic] = []
  ) -> CLICommandResult {
    guard options.output.isStructured else {
      return CLICommandResult(exitCode: exitCode, stderr: error)
    }
    let result = WorkflowInspectionFailureResult(
      workflowId: options.workflowName,
      sourceScope: options.resolution.scope,
      workflowDirectory: options.resolution.workflowDefinitionDir,
      diagnostics: diagnostics,
      error: error,
      exitCode: exitCode.rawValue
    )
    let stdout = (try? jsonString(result)) ?? #"{"diagnostics":[],"error":"failed to encode inspect failure","exitCode":1,"workflowId":"workflow inspect"}"# + "\n"
    return CLICommandResult(exitCode: exitCode, stdout: stdout)
  }
}

public struct WorkflowRunCommand: Sendable {
  public var resolver: any WorkflowBundleResolving
  public var patchApplier: any WorkflowNodePatchApplying
  public var jsonLoader: JSONReferenceLoader
  public var graphQLTransport: any WorkflowGraphQLRunTransporting
  public var jsonlRecordWriter: WorkflowJSONLRecordWriting?

  public init(
    resolver: any WorkflowBundleResolving = FileSystemWorkflowBundleResolver(),
    patchApplier: any WorkflowNodePatchApplying = DefaultWorkflowNodePatchApplier(),
    jsonLoader: JSONReferenceLoader = JSONReferenceLoader(),
    graphQLTransport: any WorkflowGraphQLRunTransporting = URLSessionWorkflowGraphQLRunTransport(),
    jsonlRecordWriter: WorkflowJSONLRecordWriting? = nil
  ) {
    self.resolver = resolver
    self.patchApplier = patchApplier
    self.jsonLoader = jsonLoader
    self.graphQLTransport = graphQLTransport
    self.jsonlRecordWriter = jsonlRecordWriter
  }

  public func run(_ options: WorkflowRunOptions) async -> CLICommandResult {
    do {
      try rejectUnsupportedRunOptions(options)
      if let endpoint = options.endpoint {
        return try await runRemote(endpoint: endpoint, options: options)
      }
      let resolution = options.resolution ?? WorkflowResolutionOptions(
        workflowName: options.target,
        workingDirectory: options.workingDirectory
      )
      var bundle = try resolveRunBundle(options: options, resolution: resolution)
      if let patch = options.nodePatch {
        bundle.nodePayloads = try patchApplier.applyNodePatch(
          jsonLoader.object(from: patch, workingDirectory: options.workingDirectory),
          to: bundle.nodePayloads
        )
      }
      let variables = try parseVariables(options.variables, workingDirectory: options.workingDirectory)
      let adapter = try makeScenarioBackedNodeAdapter(
        scenarioPath: options.mockScenarioPath,
        workingDirectory: options.workingDirectory,
        autoImprove: options.autoImprove
      )
      let stdioNodeExecutor = try makeScenarioBackedStdioNodeExecutor(
        scenarioPath: options.mockScenarioPath,
        workingDirectory: options.workingDirectory
      )
      let addonResolver = try makeScenarioBackedAddonResolver(
        scenarioPath: options.mockScenarioPath,
        workingDirectory: options.workingDirectory
      )
      let persistedResolution = CLIWorkflowSessionResolution.resolutionForPersistence(
        resolution: resolution,
        resolvedSourceScope: bundle.sourceScope
      )
      let storeRoot = CLIWorkflowSessionStore.resolveRootDirectory(
        sessionStore: options.sessionStore,
        scope: persistedResolution.scope,
        workingDirectory: options.workingDirectory
      )
      let runtimeStore = InMemoryWorkflowRuntimeStore()
      try await seedRuntimeStoreFromPersistedCLIState(runtimeStore, sessionStoreRoot: storeRoot)
      let runner = DeterministicWorkflowRunner(
        store: runtimeStore,
        adapter: adapter,
        addonResolver: addonResolver,
        stdioNodeExecutor: stdioNodeExecutor
      )
      let persistedIdentity = persistenceIdentity(
        requestedResolution: resolution,
        bundle: bundle,
        fromRegistry: options.fromRegistry
      )
      let jsonlRecorder = options.output == .jsonl ? WorkflowRunJSONLRecorder(writer: jsonlRecordWriter) : nil
      let runEventHandler: WorkflowRunEventHandler?
      if let jsonlRecorder {
        runEventHandler = { event in
          await persistLiveSessionRecordIfPresent(
            sessionId: event.sessionId,
            workflowName: persistedIdentity.workflowName,
            resolution: persistedIdentity.resolution,
            storeRoot: storeRoot,
            runtimeStore: runtimeStore,
            options: options,
            recorder: jsonlRecorder
          )
          await jsonlRecorder.append(event)
        }
      } else {
        runEventHandler = nil
      }
      let initialRequest = DeterministicWorkflowRunRequest(
        workflow: bundle.workflow,
        nodePayloads: bundle.nodePayloads,
        variables: variables,
        maxSteps: options.maxSteps,
        maxConcurrency: options.maxConcurrency,
        maxLoopIterations: options.maxLoopIterations,
        defaultTimeoutMs: options.defaultTimeoutMs,
        timeoutMs: options.timeoutMs,
        eventHandler: runEventHandler
      )
      let result: WorkflowRunResult
      do {
        result = try await runner.run(initialRequest)
      } catch {
        guard options.autoImprove, let failedSession = await runtimeStore.latestSession(workflowId: bundle.workflow.workflowId) else {
          throw error
        }
        result = WorkflowRunResult(
          workflowId: bundle.workflow.workflowId,
          session: failedSession,
          rootOutput: nil,
          exitCode: 1,
          transitions: 0
        )
      }
      var finalResult = result
      if options.autoImprove {
        finalResult = try await runAutoImproveIfNeeded(
          initialResult: finalResult,
          runner: runner,
          workflow: bundle.workflow,
          nodePayloads: bundle.nodePayloads,
          variables: variables,
          options: options
        )
      }
      let workflowMessages = try await runtimeStore.listMessages(for: finalResult.session.sessionId, toStepId: nil)
      try persistSessionRecord(
        workflowName: persistedIdentity.workflowName,
        resolution: persistedIdentity.resolution,
        resolvedSourceScope: bundle.sourceScope,
        result: finalResult,
        workflowMessages: workflowMessages,
        options: options
      )
      return CLICommandResult(
        exitCode: CLIExitCode(rawValue: finalResult.exitCode) ?? .failure,
        stdout: try await renderRunResult(finalResult, output: options.output, jsonlRecorder: jsonlRecorder)
      )
    } catch let error as CLIUsageError {
      return renderRunFailure(options: options, exitCode: .usage, error: error.message)
    } catch {
      return renderRunFailure(options: options, exitCode: .failure, error: "\(error)")
    }
  }

  private func persistLiveSessionRecordIfPresent(
    sessionId: String,
    workflowName: String,
    resolution: WorkflowResolutionOptions,
    storeRoot: String,
    runtimeStore: InMemoryWorkflowRuntimeStore,
    options: WorkflowRunOptions,
    recorder: WorkflowRunJSONLRecorder
  ) async {
    do {
      guard let session = try await runtimeStore.loadSession(id: sessionId) else {
        return
      }
      let workflowMessages = try await runtimeStore.listMessages(for: sessionId, toStepId: nil)
      try persistSessionRecord(
        workflowName: workflowName,
        resolution: resolution,
        session: session,
        workflowMessages: workflowMessages,
        storeRoot: storeRoot,
        options: options
      )
    } catch {
      await recorder.append((try? jsonString(WorkflowRunPersistenceFailureRecord(sessionId: sessionId, error: "\(error)"))) ?? "")
    }
  }

  private func runRemote(endpoint: String, options: WorkflowRunOptions) async throws -> CLICommandResult {
    if options.fromRegistry {
      throw CLIUsageError("workflow run --from-registry is local-only and cannot be combined with --endpoint")
    }
    if options.mockScenarioPath != nil {
      throw CLIUsageError("--mock-scenario cannot be combined with --endpoint")
    }
    let variables = try parseVariables(options.variables, workingDirectory: options.workingDirectory)
    let nodePatch = try options.nodePatch.map { try jsonLoader.object(from: $0, workingDirectory: options.workingDirectory) }
    let environment = CLIRuntimeEnvironment.mergedProcessEnvironment()
    let configuredAuthTokenEnv = nonEmptyString(options.authTokenEnv)
    let authTokenEnv = configuredAuthTokenEnv ?? "RIELA_MANAGER_AUTH_TOKEN"
    let authToken = nonEmptyString(options.authToken)
      ?? nonEmptyString(environment[authTokenEnv])
      ?? (configuredAuthTokenEnv == nil ? nonEmptyString(environment["RIEL_MANAGER_AUTH_TOKEN"]) : nil)
    let managerSessionId = nonEmptyString(environment["RIELA_MANAGER_SESSION_ID"])
      ?? nonEmptyString(environment["RIEL_MANAGER_SESSION_ID"])
    let request = WorkflowRemoteRunRequest(
      workflowName: options.target,
      runtimeVariables: variables,
      nodePatch: nodePatch,
      autoImprove: options.autoImprove,
      autoImprovePolicy: options.autoImprovePolicy,
      maxSteps: options.maxSteps,
      maxConcurrency: options.maxConcurrency,
      maxLoopIterations: options.maxLoopIterations,
      defaultTimeoutMs: options.defaultTimeoutMs,
      timeoutMs: options.timeoutMs,
      authToken: authToken,
      authTokenEnv: authTokenEnv,
      managerSessionId: managerSessionId
    )
    let result = try await graphQLTransport.executeWorkflow(endpoint: endpoint, request: request)
    return CLICommandResult(
      exitCode: CLIExitCode(rawValue: result.exitCode) ?? .failure,
      stdout: try renderRemoteRunResult(result, output: options.output)
    )
  }

  private func parseVariables(_ reference: String?, workingDirectory: String) throws -> JSONObject {
    guard let reference else {
      return [:]
    }
    return try jsonLoader.object(from: reference, workingDirectory: workingDirectory)
  }

  private func rejectUnsupportedRunOptions(_ options: WorkflowRunOptions) throws {
    if options.fromRegistry && isTemporaryWorkflowRunTarget(options.target, workingDirectory: options.workingDirectory) {
      throw CLIUsageError("temporary workflow JSON cannot be combined with --from-registry")
    }
  }

  private func persistSessionRecord(
    workflowName: String,
    resolution: WorkflowResolutionOptions,
    resolvedSourceScope: WorkflowScope,
    result: WorkflowRunResult,
    workflowMessages: [WorkflowMessageRecord],
    options: WorkflowRunOptions
  ) throws {
    let persistedResolution = CLIWorkflowSessionResolution.resolutionForPersistence(
      resolution: resolution,
      resolvedSourceScope: resolvedSourceScope
    )
    let storeRoot = CLIWorkflowSessionStore.resolveRootDirectory(
      sessionStore: options.sessionStore,
      scope: persistedResolution.scope,
      workingDirectory: options.workingDirectory
    )
    try CLIWorkflowSessionStore(rootDirectory: storeRoot).save(
      PersistedCLIWorkflowSession(
        workflowName: workflowName,
        session: result.session,
        resolution: persistedResolution,
        mockScenarioPath: options.mockScenarioPath
      )
    )
    let snapshot = WorkflowRuntimePersistenceProjector.snapshot(session: result.session, workflowMessages: workflowMessages)
    try FileWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: storeRoot)).save(snapshot)
    if let artifactRoot = options.artifactRoot {
      let artifactURL = absoluteURL(artifactRoot, relativeTo: URL(fileURLWithPath: options.workingDirectory, isDirectory: true))
      try FileWorkflowRuntimePersistenceStore(rootDirectory: artifactURL.path).save(snapshot)
    }
    if options.autoImprove, let supervision = result.supervision {
      try persistSupervisionRecord(
        sessionId: result.session.sessionId,
        storeRoot: storeRoot,
        workflowName: workflowName,
        supervision: supervision
      )
    }
  }

  private func persistSessionRecord(
    workflowName: String,
    resolution: WorkflowResolutionOptions,
    session: WorkflowSession,
    workflowMessages: [WorkflowMessageRecord],
    storeRoot: String,
    options: WorkflowRunOptions
  ) throws {
    try CLIWorkflowSessionStore(rootDirectory: storeRoot).save(
      PersistedCLIWorkflowSession(
        workflowName: workflowName,
        session: session,
        resolution: resolution,
        mockScenarioPath: options.mockScenarioPath
      )
    )
    let snapshot = WorkflowRuntimePersistenceProjector.snapshot(session: session, workflowMessages: workflowMessages)
    try FileWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: storeRoot)).save(snapshot)
    if let artifactRoot = options.artifactRoot {
      let artifactURL = absoluteURL(artifactRoot, relativeTo: URL(fileURLWithPath: options.workingDirectory, isDirectory: true))
      try FileWorkflowRuntimePersistenceStore(rootDirectory: artifactURL.path).save(snapshot)
    }
  }

  private func persistenceIdentity(
    requestedResolution: WorkflowResolutionOptions,
    bundle: ResolvedWorkflowBundle,
    fromRegistry: Bool
  ) -> (workflowName: String, resolution: WorkflowResolutionOptions) {
    guard fromRegistry else {
      return (requestedResolution.workflowName, requestedResolution)
    }
    return (
      bundle.workflow.workflowId,
      WorkflowResolutionOptions(
        workflowName: bundle.workflow.workflowId,
        scope: bundle.sourceScope,
        workflowDefinitionDir: bundle.workflowDirectory,
        workingDirectory: requestedResolution.workingDirectory
      )
    )
  }

  private func persistSupervisionRecord(
    sessionId: String,
    storeRoot: String,
    workflowName: String,
    supervision: JSONObject
  ) throws {
    let directory = URL(fileURLWithPath: canonicalRuntimeStoreRoot(sessionStoreRoot: storeRoot), isDirectory: true)
      .appendingPathComponent(sessionId, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var record = supervision
    record["sessionId"] = .string(sessionId)
    record["workflowName"] = .string(workflowName)
    try jsonString(record).write(to: directory.appendingPathComponent("supervision-record.json"), atomically: true, encoding: .utf8)
  }

  private func runAutoImproveIfNeeded(
    initialResult: WorkflowRunResult,
    runner: DeterministicWorkflowRunner,
    workflow: WorkflowDefinition,
    nodePayloads: [String: AgentNodePayload],
    variables: JSONObject,
    options: WorkflowRunOptions
  ) async throws -> WorkflowRunResult {
    var current = initialResult
    var incidents: [JSONValue] = []
    var remediations: [JSONValue] = []
    var supervisedAttempts = 1

    while current.status == .failed && supervisedAttempts < options.autoImprovePolicy.maxSupervisedAttempts {
      let failedExecution = current.session.executions.last { $0.status == .failed }
      let targetStepId = failedExecution?.stepId ?? workflow.entryStepId
      let incidentId = "incident-\(supervisedAttempts)"
      incidents.append(.object([
        "incidentId": .string(incidentId),
        "category": .string("failure"),
        "sessionId": .string(current.session.sessionId),
        "stepId": .string(targetStepId),
        "executionId": .string(failedExecution?.executionId ?? ""),
        "message": .string(failedExecution?.failureReason ?? "workflow failed")
      ]))

      let sourceSessionId = current.session.sessionId
      supervisedAttempts += 1
      let rerun = try await runner.run(
        DeterministicWorkflowRunRequest(
          workflow: workflow,
          nodePayloads: nodePayloads,
          variables: variables,
          maxSteps: options.maxSteps,
          maxConcurrency: options.maxConcurrency,
          maxLoopIterations: options.maxLoopIterations,
          defaultTimeoutMs: options.defaultTimeoutMs,
          timeoutMs: options.timeoutMs,
          rerunFromSessionId: sourceSessionId,
          rerunFromStepId: targetStepId
        )
      )
      remediations.append(.object([
        "remediationId": .string("remediation-\(supervisedAttempts - 1)"),
        "incidentId": .string(incidentId),
        "action": .string("rerun-workflow"),
        "managerControl": .string("session rerun"),
        "sourceSessionId": .string(sourceSessionId),
        "targetSessionId": .string(rerun.session.sessionId),
        "targetStepId": .string(targetStepId)
      ]))
      current = rerun
    }

    current.supervision = supervisionRecord(
      status: current.status == .completed ? "succeeded" : "failed",
      policy: options.autoImprovePolicy,
      targetSessionId: current.session.sessionId,
      attempts: supervisedAttempts,
      incidents: incidents,
      remediations: remediations
    )
    return current
  }

  private func supervisionRecord(
    status: String,
    policy: WorkflowAutoImprovePolicy,
    targetSessionId: String,
    attempts: Int,
    incidents: [JSONValue],
    remediations: [JSONValue]
  ) -> JSONObject {
    [
      "supervisionRunId": .string("supervision-\(targetSessionId)"),
      "targetSessionId": .string(targetSessionId),
      "mode": .string("auto-improve"),
      "status": .string(status),
      "attempts": .number(Double(attempts)),
      "policy": .object([
        "maxSupervisedAttempts": .number(Double(policy.maxSupervisedAttempts)),
        "maxWorkflowPatches": .number(Double(policy.maxWorkflowPatches)),
        "monitorIntervalMs": .number(Double(policy.monitorIntervalMs)),
        "stallTimeoutMs": .number(Double(policy.stallTimeoutMs)),
        "workflowMutationMode": .string(policy.workflowMutationMode.rawValue),
        "nestedSuperviser": .bool(policy.nestedSuperviser)
      ]),
      "incidents": .array(incidents),
      "remediations": .array(remediations),
      "managerControl": .object([
        "transport": .string("local-runtime"),
        "targetedRerun": .bool(!remediations.isEmpty),
        "command": .string("session rerun")
      ])
    ]
  }

  private func resolveRunBundle(options: WorkflowRunOptions, resolution: WorkflowResolutionOptions) throws -> ResolvedWorkflowBundle {
    if let temporary = try loadTemporaryWorkflowIfPresent(options.target, workingDirectory: options.workingDirectory) {
      return temporary
    }
    if options.fromRegistry {
      return try resolveRegistryRunBundle(options: options)
    }
    return try resolver.resolve(resolution)
  }

  private func resolveRegistryRunBundle(options: WorkflowRunOptions) throws -> ResolvedWorkflowBundle {
    guard WorkflowPackageManifestValidator.isSafePackageName(options.target) else {
      throw CLIUsageError("invalid package name '\(options.target)'")
    }
    let workingDirectory = URL(fileURLWithPath: options.workingDirectory, isDirectory: true)
    let roots: [(scope: WorkflowScope, root: URL)]
    switch options.resolution?.scope ?? .auto {
    case .project:
      roots = [(.project, workflowRunPackageRoot(scope: .project, workingDirectory: workingDirectory))]
    case .user:
      roots = [(.user, workflowRunPackageRoot(scope: .user, workingDirectory: workingDirectory))]
    case .auto, .direct:
      roots = [
        (.project, workflowRunPackageRoot(scope: .project, workingDirectory: workingDirectory)),
        (.user, workflowRunPackageRoot(scope: .user, workingDirectory: workingDirectory))
      ]
    }
    var errors: [String] = []
    for (scope, root) in roots {
      let packageDirectory = root.appendingPathComponent(options.target, isDirectory: true).standardizedFileURL
      let manifestURL = packageDirectory.appendingPathComponent("riela-package.json")
      guard FileManager.default.fileExists(atPath: manifestURL.path) else {
        errors.append("\(manifestURL.path) not found")
        continue
      }
      let manifest = try JSONDecoder().decode(WorkflowPackageManifest.self, from: Data(contentsOf: manifestURL))
      let issues = WorkflowPackageManifestValidator.validate(manifest)
        + WorkflowPackageManifestValidator.validateWorkflowBundle(manifest, packageRoot: packageDirectory)
      guard issues.isEmpty else {
        throw CLIUsageError("package source validation failed: \(issues.map { "\($0.path): \($0.message)" }.joined(separator: "; "))")
      }
      guard let normalizedWorkflowDirectory = WorkflowPackageManifestValidator.normalizePackageRelativePath(manifest.workflowDirectory ?? ".") else {
        throw CLIUsageError("package workflowDirectory must be package-relative")
      }
      let workflowDirectory = packageDirectory
        .appendingPathComponent(normalizedWorkflowDirectory, isDirectory: true)
        .standardizedFileURL
      guard workflowRunPath(workflowDirectory.resolvingSymlinksInPath(), isContainedIn: packageDirectory.resolvingSymlinksInPath()) else {
        throw CLIUsageError("package workflowDirectory escapes package root: \(manifest.workflowDirectory ?? ".")")
      }
      var bundle = try resolver.resolve(WorkflowResolutionOptions(
        workflowName: workflowDirectory.lastPathComponent,
        scope: .direct,
        workflowDefinitionDir: workflowDirectory.path,
        workingDirectory: options.workingDirectory
      ))
      bundle.sourceScope = scope
      return bundle
    }
    throw WorkflowResolutionError.notFound(options.target, errors)
  }

  private func loadTemporaryWorkflowIfPresent(_ target: String, workingDirectory: String) throws -> ResolvedWorkflowBundle? {
    let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
    let data: Data
    let directory: URL
    if trimmed.hasPrefix("{") {
      guard let inlineData = trimmed.data(using: .utf8) else {
        throw CLIUsageError("temporary workflow JSON target must be UTF-8")
      }
      data = inlineData
      directory = URL(fileURLWithPath: workingDirectory)
    } else {
      let url = absoluteURL(target, relativeTo: URL(fileURLWithPath: workingDirectory))
      guard FileManager.default.fileExists(atPath: url.path), url.pathExtension == "json" else {
        return nil
      }
      data = try Data(contentsOf: url)
      directory = url.deletingLastPathComponent()
    }

    if let payload = try? JSONDecoder().decode(TemporaryWorkflowPayload.self, from: data) {
      let authoredData = try JSONEncoder().encode(payload.workflow)
      let validation = validateAuthoredWorkflowData(authoredData)
      guard let workflow = validation.workflow else {
        throw WorkflowResolutionError.invalidWorkflow(validation.diagnostics)
      }
      return ResolvedWorkflowBundle(
        workflow: workflow,
        nodePayloads: nodePayloads(from: payload, workflow: workflow),
        sourceScope: .direct,
        workflowDirectory: directory.path,
        diagnostics: validation.diagnostics
      )
    }

    let validation = validateAuthoredWorkflowData(data)
    guard let workflow = validation.workflow else {
      throw WorkflowResolutionError.invalidWorkflow(validation.diagnostics)
    }
    return ResolvedWorkflowBundle(
      workflow: workflow,
      nodePayloads: [:],
      sourceScope: .direct,
      workflowDirectory: directory.path,
      diagnostics: validation.diagnostics
    )
  }

  private func nodePayloads(from payload: TemporaryWorkflowPayload, workflow: WorkflowDefinition) -> [String: AgentNodePayload] {
    var byNodeId: [String: AgentNodePayload] = [:]
    for registryNode in workflow.nodeRegistry {
      if let nodeFile = registryNode.nodeFile, let nodePayload = payload.nodePayloads[nodeFile] {
        byNodeId[registryNode.id] = nodePayload
      } else if let nodePayload = payload.nodePayloads[registryNode.id] {
        byNodeId[registryNode.id] = nodePayload
      }
    }
    return byNodeId
  }

  private func renderRunResult(
    _ result: WorkflowRunResult,
    output: WorkflowOutputFormat,
    jsonlRecorder: WorkflowRunJSONLRecorder?
  ) async throws -> String {
    switch output {
    case .json:
      return try jsonString(result)
    case .jsonl:
      let record = try jsonString(WorkflowRunResultRecord(result: result))
      if let jsonlRecorder {
        await jsonlRecorder.append(record)
        return await jsonlRecorder.bufferedOutput()
      }
      return record
    case .text, .table:
      return "status: \(result.session.status.rawValue)\nworkflowId: \(result.workflowId)\nnodeExecutions: \(result.session.executions.count)\n"
    }
  }

  private func renderRemoteRunResult(_ result: WorkflowRemoteRunResult, output: WorkflowOutputFormat) throws -> String {
    switch output {
    case .json:
      return try jsonString(result)
    case .jsonl:
      return try jsonString(WorkflowRemoteRunResultRecord(result: result))
    case .text, .table:
      return "run session: \(result.sessionId)\nstatus: \(result.status)\nnodeExecutions: \(result.nodeExecutions)\n"
    }
  }

  private func renderRunFailure(options: WorkflowRunOptions, exitCode: CLIExitCode, error: String) -> CLICommandResult {
    guard options.output.isStructured else {
      return CLICommandResult(exitCode: exitCode, stderr: error)
    }
    let result = WorkflowRunFailureResult(target: options.target, exitCode: exitCode.rawValue, error: error)
    let stdout = (try? jsonString(result)) ?? #"{"error":"failed to encode run failure","exitCode":1,"status":"failed","target":"workflow run"}"# + "\n"
    return CLICommandResult(exitCode: exitCode, stdout: stdout)
  }
}

private struct TemporaryWorkflowPayload: Codable {
  var workflow: AuthoredWorkflowJSON
  var nodePayloads: [String: AgentNodePayload]
}

private func isTemporaryWorkflowRunTarget(_ target: String, workingDirectory: String) -> Bool {
  if target.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
    return true
  }
  let url = absoluteURL(target, relativeTo: URL(fileURLWithPath: workingDirectory, isDirectory: true))
  return FileManager.default.fileExists(atPath: url.path) && url.pathExtension == "json"
}

private func workflowRunPackageRoot(scope: WorkflowScope, workingDirectory: URL) -> URL {
  switch scope {
  case .user:
    return URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory()).appendingPathComponent(".riela/packages", isDirectory: true)
  case .auto, .project, .direct:
    return workingDirectory.appendingPathComponent(".riela/packages", isDirectory: true)
  }
}

private func workflowRunPath(_ child: URL, isContainedIn parent: URL) -> Bool {
  let parentPath = parent.standardizedFileURL.path
  let childPath = child.standardizedFileURL.path
  return childPath == parentPath || childPath.hasPrefix(parentPath + "/")
}

public struct RielaCLIApplication: Sendable {
  public var parser: any CLIArgumentParsing
  public var validateCommand: WorkflowValidateCommand
  public var inspectCommand: WorkflowInspectCommand
  public var runCommand: WorkflowRunCommand
  public var manifestValidateCommand: WorkflowManifestValidateCommand
  public var workflowCatalogCommand: WorkflowCatalogCommand
  public var sessionRerunCommand: SessionRerunCommand
  public var sessionResumeCommand: SessionResumeCommand
  public var sessionInspectionCommand: SessionInspectionCommand
  public var workflowScaffoldCommand: WorkflowScaffoldCommand
  public var packageCommandRunner: WorkflowPackageCommandRunner
  public var memoryCommandRunner: MemoryCommandRunner
  public var sessionContinueCommand: SessionContinueCommand
  public var scopedCommandRunner: ScopedParityCommandRunner

  public init(
    parser: any CLIArgumentParsing = RielaArgumentParser(),
    validateCommand: WorkflowValidateCommand = WorkflowValidateCommand(),
    inspectCommand: WorkflowInspectCommand = WorkflowInspectCommand(),
    runCommand: WorkflowRunCommand = WorkflowRunCommand(),
    manifestValidateCommand: WorkflowManifestValidateCommand = WorkflowManifestValidateCommand(),
    workflowCatalogCommand: WorkflowCatalogCommand = WorkflowCatalogCommand(),
    sessionRerunCommand: SessionRerunCommand = SessionRerunCommand(),
    sessionResumeCommand: SessionResumeCommand = SessionResumeCommand(),
    sessionInspectionCommand: SessionInspectionCommand = SessionInspectionCommand(),
    workflowScaffoldCommand: WorkflowScaffoldCommand = WorkflowScaffoldCommand(),
    packageCommandRunner: WorkflowPackageCommandRunner = WorkflowPackageCommandRunner(),
    memoryCommandRunner: MemoryCommandRunner = MemoryCommandRunner(),
    sessionContinueCommand: SessionContinueCommand = SessionContinueCommand(),
    scopedCommandRunner: ScopedParityCommandRunner = ScopedParityCommandRunner()
  ) {
    self.parser = parser
    self.validateCommand = validateCommand
    self.inspectCommand = inspectCommand
    self.runCommand = runCommand
    self.manifestValidateCommand = manifestValidateCommand
    self.workflowCatalogCommand = workflowCatalogCommand
    self.sessionRerunCommand = sessionRerunCommand
    self.sessionResumeCommand = sessionResumeCommand
    self.sessionInspectionCommand = sessionInspectionCommand
    self.workflowScaffoldCommand = workflowScaffoldCommand
    self.packageCommandRunner = packageCommandRunner
    self.memoryCommandRunner = memoryCommandRunner
    self.sessionContinueCommand = sessionContinueCommand
    self.scopedCommandRunner = scopedCommandRunner
  }

  public func run(_ arguments: [String]) async -> CLICommandResult {
    await run(arguments, environment: nil)
  }

  public func run(_ arguments: [String], environment: [String: String]?) async -> CLICommandResult {
    if let environment {
      return await CLIRuntimeEnvironment.$overrides.withValue(environment) {
        await runParsed(arguments)
      }
    }
    return await runParsed(arguments)
  }

  private func runParsed(_ arguments: [String]) async -> CLICommandResult {
    do {
      switch try parser.parse(arguments) {
      case .help:
        return CLICommandResult(exitCode: .success, stdout: rielaCLIHelpText)
      case .version:
        return CLICommandResult(exitCode: .success, stdout: "\(rielaSwiftMigrationVersion)\n")
      case let .workflow(.validate(options)):
        return await validateCommand.run(options)
      case let .workflow(.inspect(options)):
        return inspectCommand.run(options)
      case let .workflow(.usage(options)):
        return inspectCommand.run(options)
      case let .workflow(.run(options)):
        return await runCommand.run(options)
      case let .workflow(.list(options)):
        return workflowCatalogCommand.list(options)
      case let .workflow(.status(options)):
        return workflowCatalogCommand.status(options)
      case let .workflow(.manifestValidate(options)):
        return await manifestValidateCommand.run(options)
      case let .workflow(.checkout(options)):
        return workflowScaffoldCommand.checkout(options)
      case let .workflow(.create(options)):
        return workflowScaffoldCommand.create(options)
      case let .workflow(.selfImprove(options)):
        return workflowScaffoldCommand.selfImprove(options)
      case let .workflow(.package(command)):
        return await packageCommandRunner.run(command)
      case let .session(.rerun(options)):
        return await sessionRerunCommand.run(options)
      case let .session(.resume(options)):
        return await sessionResumeCommand.run(options)
      case let .session(.progress(options)):
        return sessionInspectionCommand.run(options)
      case let .session(.health(options)):
        return sessionInspectionCommand.run(options)
      case let .session(.status(options)):
        return sessionInspectionCommand.run(options)
      case let .session(.continueSession(options)):
        return await sessionContinueCommand.run(options)
      case let .session(.stepRuns(options)):
        return sessionInspectionCommand.run(options)
      case let .session(.export(options)):
        return sessionInspectionCommand.run(options)
      case let .session(.logs(options)):
        return sessionInspectionCommand.run(options)
      case let .package(command):
        return await packageCommandRunner.run(command)
      case let .memory(command):
        return memoryCommandRunner.run(command)
      case let .scoped(command):
        return await scopedCommandRunner.run(command)
      }
    } catch let error as CLIUsageError {
      return renderParserFailure(arguments: arguments, error: error)
    } catch {
      return CLICommandResult(exitCode: .failure, stderr: "\(error)")
    }
  }

  private func renderParserFailure(arguments: [String], error: CLIUsageError) -> CLICommandResult {
    guard requestsStructuredOutput(arguments) else {
      return CLICommandResult(exitCode: .usage, stderr: error.message)
    }
    guard arguments.first == "workflow" else {
      let result = CLIUnsupportedCommandResult(
        scope: arguments.first ?? "riela",
        command: arguments.dropFirst().first,
        target: arguments.dropFirst(2).first,
        exitCode: CLIExitCode.usage.rawValue,
        error: error.message
      )
      return CLICommandResult(
        exitCode: .usage,
        stdout: (try? jsonString(result)) ?? #"{"error":"failed to encode parser failure","exitCode":2}"# + "\n"
      )
    }
    let subcommand = arguments.count > 1 ? arguments[1] : "workflow"
    let target = parserFailureTarget(arguments: arguments, subcommand: subcommand)
    let exitCode = CLIExitCode.usage.rawValue
    let stdout: String?
    switch subcommand {
    case "validate":
      stdout = try? jsonString(WorkflowValidationFailureResult(
        workflowId: target,
        error: error.message,
        exitCode: exitCode
      ))
    case "inspect":
      stdout = try? jsonString(WorkflowInspectionFailureResult(
        workflowId: target,
        error: error.message,
        exitCode: exitCode
      ))
    case "run":
      stdout = try? jsonString(WorkflowRunFailureResult(
        target: target,
        exitCode: exitCode,
        error: error.message
      ))
    default:
      stdout = try? jsonString(WorkflowRunFailureResult(
        target: target,
        exitCode: exitCode,
        error: error.message
      ))
    }
    return CLICommandResult(
      exitCode: .usage,
      stdout: stdout ?? #"{"error":"failed to encode parser failure","exitCode":2}"# + "\n"
    )
  }

  private func requestsStructuredOutput(_ arguments: [String]) -> Bool {
    for index in arguments.indices {
      if arguments[index] == "--output", index + 1 < arguments.count {
        return arguments[index + 1] != "text" && arguments[index + 1] != "table"
      }
      if arguments[index].hasPrefix("--output=") {
        let value = String(arguments[index].dropFirst("--output=".count))
        return value != "text" && value != "table"
      }
    }
    return true
  }

  private func parserFailureTarget(arguments: [String], subcommand: String) -> String {
    guard arguments.count > 2, !arguments[2].hasPrefix("--") else {
      return "workflow \(subcommand)"
    }
    return arguments[2]
  }

}

public struct CLIUnsupportedCommandResult: Codable, Equatable, Sendable {
  public var scope: String
  public var command: String?
  public var target: String?
  public var exitCode: Int32
  public var error: String

  public init(scope: String, command: String?, target: String?, exitCode: Int32, error: String) {
    self.scope = scope
    self.command = command
    self.target = target
    self.exitCode = exitCode
    self.error = error
  }
}

actor SupervisedScenarioNodeAdapter: NodeAdapter {
  private let scenario: WorkflowMockScenario
  private let fallback: any NodeAdapter
  private var callCounts: [String: Int] = [:]

  init(scenario: WorkflowMockScenario, fallback: any NodeAdapter = DeterministicLocalNodeAdapter()) {
    self.scenario = scenario
    self.fallback = fallback
  }

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    guard let sequence = scenario.responses[input.node.id] else {
      return try await fallback.execute(input, context: context)
    }
    let nextIndex = (callCounts[input.node.id] ?? 0) + 1
    callCounts[input.node.id] = nextIndex
    let response = sequence.isEmpty ? MockNodeResponse() : sequence[min(nextIndex - 1, sequence.count - 1)]
    if response.fail == true {
      throw AdapterExecutionError(.providerError, "scenario forced failure for node '\(input.node.id)'")
    }
    return AdapterExecutionOutput(
      provider: response.provider ?? "scenario-mock",
      model: response.model ?? input.node.model,
      promptText: response.promptText ?? input.promptText,
      completionPassed: response.completionPassed ?? true,
      when: response.when ?? ["always": true],
      payload: response.payload ?? [:]
    )
  }
}

public let rielaCLIHelpText = """
Riela CLI

Usage:
  riela --version
  riela workflow validate <workflow> [--scope project|user|auto] [--output jsonl|json|text]
  riela workflow inspect <workflow> [--scope project|user|auto] [--output jsonl|json|text]
  riela workflow usage <workflow> [--scope project|user|auto] [--output jsonl|json|text]
  riela workflow list|status [--output jsonl|json|text|table]
  riela workflow manifest validate <manifest-path> [--output jsonl|json|text]
  riela workflow checkout|create|self-improve <workflow> [options]
  riela workflow package <search|list|status|install|update|remove|checkout|publish> [options]
  riela workflow run <workflow> --mock-scenario <path> [--auto-improve] [--output jsonl|json|text]
  riela package <search|list|status|install|update|remove|checkout|publish> [options]
  riela memory save <memory-id> --workflow-id <workflow> --payload-json <json> [--node-id <node>] [--tag <tag>] [--related-id <id>] [--memory-root <dir>]
  riela memory update <memory-id> --workflow-id <workflow> --record-id <id> --payload-json <json> [--tag <tag>] [--related-id <id>] [--memory-root <dir>]
  riela memory load|search <memory-id> --workflow-id <workflow> [--match <regex>] [--tag <tag>] [--related-id <id>] [--limit 30] [--memory-root <dir>]
  riela memory metadata|tags|related-ids <memory-id> [--limit 30] [--offset 0] [--sort value-asc|value-desc] [--memory-root <dir>]
  riela session rerun <session-id> <step-id> [--scope project|user|auto] [--output jsonl|json|text]
  riela session resume <session-id> [--scope project|user|auto] [--output jsonl|json|text]
  riela session progress|health|status|continue|step-runs|export|logs [session-id] [options]
  riela graphql|gql|hook|events|serve|call-step|workflow-call [command] [target] [options]

Output defaults to JSONL for machine-readable commands. Use --output text for human-readable output or --output json for the legacy single JSON document.

The Swift CLI is the production Homebrew runtime. The formula installs only the riela command on macOS; Linux users install CLI release tarballs directly. The macOS Cask installs RielaApp.app and riela together.

"""

func jsonString<T: Encodable>(_ value: T) throws -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  encoder.dateEncodingStrategy = .iso8601
  let data = try encoder.encode(value)
  guard let json = String(data: data, encoding: .utf8) else {
    throw CLIUsageError("failed to encode JSON as UTF-8")
  }
  return json + "\n"
}
