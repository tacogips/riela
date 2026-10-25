import Foundation
import RielaAdapters
import RielaCore

/// Explicit worker capabilities. Protocol v1-v3 encoded these implicitly in the
/// version number (1 legacy, 2 ephemeral HOME, 3 native schema); v4 states each
/// one so a new capability never needs another implicit version rule.
enum SandboxNodeCapability: String, Codable, Sendable, CaseIterable {
  case ephemeralHome = "ephemeral-home"
  case nativeStructuredOutput = "native-structured-output"
  /// The host decodes `rejected` records and rethrows them as validation
  /// rejections so the runner's `maxValidationAttempts` loop applies.
  case validationRejection = "validation-rejection"
}

struct SandboxNodeRequest: Codable, Sendable {
  static let currentVersion = 4
  /// Last versions whose hosts cannot decode `rejected` records.
  static let legacyVersions = 1...3
  var version = currentVersion
  var capabilities: Set<SandboxNodeCapability>?
  var input: AdapterExecutionInput
  var deadline: Date?
  var previousVendorSessionId: String?
  var supervisorMode: Bool
  var ephemeralHome: Bool?
  var credentials: [SandboxRuntimeCredential]?

  /// The exact capability set a request needs; workers refuse any other set.
  static func requiredCapabilities(ephemeralHome: Bool, output: NodeOutputContract?) -> Set<SandboxNodeCapability> {
    var result: Set<SandboxNodeCapability> = [.validationRejection]
    if ephemeralHome { result.insert(.ephemeralHome) }
    if output?.nativeStructuredOutput == true { result.insert(.nativeStructuredOutput) }
    return result
  }
}

struct SandboxRuntimeCredential: Codable, Sendable {
  var homePath: String
  var value: String
}

struct SandboxNodeRecord: Codable, Sendable {
  /// v2 adds `rejected`. A v1 record comes from a worker that predates it.
  static let currentVersion = 2
  static let maximumRejectionBytes = 4096
  enum Kind: String, Codable, Sendable { case event, result, failure, rejected }
  var version = currentVersion
  var kind: Kind
  var event: AdapterBackendEvent?
  var output: AdapterExecutionOutput?
  var failure: BuiltinAddonContainerFailure?
  /// Output-contract rejection reason (fixed text for ephemeral guests).
  var rejection: String?
  var vendorSessionId: String?
}

/// Hosts the linked gateway inside the enforced process boundary, including
/// SDK HTTP calls and vendor CLI subprocesses. It owns no runtime session IDs.
enum SandboxNodeWorker {
  static let command = "__riela-node-worker"
  static let addonCommand = "__riela-addon-worker"

  static func run() async {
    let writer = SandboxNodeRecordWriter()
    let operation = Task { await execute(writer: writer) }
    let cancellation = CLISignalCancellation { _ in operation.cancel() }
    await operation.value
    cancellation.cancel()
  }

  private static func execute(writer: SandboxNodeRecordWriter) async {
    do {
      let request = try readRequest()
      guard request.version == SandboxNodeRequest.currentVersion else {
        // Old hosts decode only v1 records; answer them with a v1 failure they understand.
        writer.emit(legacyRefusal(version: request.version))
        return
      }
      let ephemeral = request.ephemeralHome == true
      guard request.capabilities == SandboxNodeRequest.requiredCapabilities(ephemeralHome: ephemeral,
              output: request.input.node.output), request.input.node.sandbox == nil else {
        throw AdapterExecutionError(.invalidInput, "invalid isolated node worker request")
      }
      if ephemeral { _ = try privateContract(request.input.node.output) }
      try prepareEphemeralHome(request)
      let sessionStore = AgentGatewaySessionStore()
      if let previous = request.previousVendorSessionId,
         request.input.sessionPolicy?.mode == .reuse, let key = sessionKey(request.input, inheriting: true) {
        sessionStore.setSessionId(previous, for: key)
      }
      let adapter = AgentGatewayNodeAdapter(environment: ProcessInfo.processInfo.environment,
        codexSupervisorModeEnabled: request.supervisorMode,
        defaultWorkingDirectory: FileManager.default.currentDirectoryPath, sessionStore: sessionStore)
      let vendorSession = { ephemeral ? nil : sessionKey(request.input).flatMap(sessionStore.sessionId(for:)) }
      let output: AdapterExecutionOutput
      do {
        let streamingHandler: AdapterBackendEventHandler = { event in
          writer.emit(.init(kind: .event, event: event))
        }
        let result = try await adapter.execute(request.input, context: .init(deadline: request.deadline,
          backendEventHandler: ephemeral ? nil : streamingHandler))
        output = ephemeral
          ? try privateOutput(result, contract: request.input.node.output, configuredModel: request.input.node.model)
          : result
        if let failure = writer.failure { throw failure }
      } catch {
        writer.emit(terminalRecord(for: error, ephemeral: ephemeral, vendorSessionId: vendorSession()))
        return
      }
      writer.emit(.init(kind: .result, output: output, vendorSessionId: vendorSession()))
    } catch {
      let failure = error is EmptyWorkerInput
        ? AdapterExecutionError(.invalidInput, WorkerJSONLInput.nodeEmptyMessage)
        : (error as? AdapterExecutionError)
      writer.emit(.init(kind: .failure, failure: .init(failure
        ?? .init(.invalidInput, "invalid isolated node worker input"))))
    }
  }

  static func legacyRefusal(version: Int) -> SandboxNodeRecord {
    var record = SandboxNodeRecord(kind: .failure, failure: .init(.init(.policyBlocked,
      "isolated node worker protocol version is unsupported")))
    if SandboxNodeRequest.legacyVersions.contains(version) { record.version = 1 }
    return record
  }

  /// Maps an execution error to the single terminal record. Output-contract
  /// rejections stay retryable by the controller's validation loop.
  static func terminalRecord(for error: Error, ephemeral: Bool, vendorSessionId: String?) -> SandboxNodeRecord {
    if case let WorkflowPublicationError.validationRejected(reason) = error {
      return .init(kind: .rejected, rejection: ephemeral ? privateRejectionMessage : boundedRejection(reason),
        vendorSessionId: ephemeral ? nil : vendorSessionId)
    }
    let failure = ephemeral ? privateFailure(error)
      : (error as? AdapterExecutionError) ?? .init(.providerError, "isolated node worker execution failed")
    return .init(kind: .failure, failure: .init(failure), vendorSessionId: ephemeral ? nil : vendorSessionId)
  }

  static func boundedRejection(_ reason: String) -> String {
    let text = reason.isEmpty ? "output validation rejected candidate" : reason
    guard text.utf8.count > SandboxNodeRecord.maximumRejectionBytes else { return text }
    var result = ""
    for character in text {
      guard result.utf8.count + String(character).utf8.count <= SandboxNodeRecord.maximumRejectionBytes - 3 else { break }
      result.append(character)
    }
    return result + "..."
  }

  static let privateRejectionMessage = "ephemeral agent output contract rejected"
  private static let privateRoutingLabel = #"^[A-Za-z0-9_.-]{1,64}$"#
  private static let privateMetadataValue = #"^[A-Za-z0-9][A-Za-z0-9_.:/@+-]{0,127}$"#
  static let maximumPrivateRoutingLabels = 32

  /// Only finite, label-shaped routing keys may leave a private boundary; free
  /// text in `when` would bypass the export schema.
  static func privateRoutingIsBounded(_ when: [String: Bool]) -> Bool {
    when.count <= maximumPrivateRoutingLabels
      && when.keys.allSatisfy { $0.range(of: privateRoutingLabel, options: .regularExpression) != nil }
  }

  static func boundedPrivateMetadata(_ value: String?) -> String? {
    guard let value, value.range(of: privateMetadataValue, options: .regularExpression) != nil else { return nil }
    return value
  }

  /// Throws `WorkflowPublicationError.validationRejected` with fixed text for an
  /// agent answer that violates the contract, so the controller may retry it.
  static func privateOutput(_ output: AdapterExecutionOutput, contract: NodeOutputContract?,
                            configuredModel: String? = nil) throws -> AdapterExecutionOutput {
    let schema = try privateContract(contract)
    guard privateRoutingIsBounded(output.when) else {
      throw WorkflowPublicationError.validationRejected(privateRejectionMessage)
    }
    let accepted = try DefaultWorkflowOutputValidator().validate(
      .init(source: .adapterOutput, payload: output.payload, completionPassed: output.completionPassed),
      contract: .init(schema: schema, requiredObject: true))
    guard accepted.status == .accepted else {
      throw WorkflowPublicationError.validationRejected(privateRejectionMessage)
    }
    var result = output
    result.promptText = ""
    result.provider = boundedPrivateMetadata(output.provider) ?? "unreported"
    result.model = boundedPrivateMetadata(output.model) ?? boundedPrivateMetadata(configuredModel) ?? "unreported"
    result.usage = output.usage.map { .init(inputTokens: $0.inputTokens, outputTokens: $0.outputTokens,
      totalTokens: $0.totalTokens, cacheReadInputTokens: $0.cacheReadInputTokens,
      cacheCreationInputTokens: $0.cacheCreationInputTokens) }
    return result
  }

  static func privateContract(_ contract: NodeOutputContract?) throws -> JSONObject {
    guard let schema = contract?.jsonSchema,
          DefaultWorkflowOutputValidator().validateContractSchema(schema) == nil else {
      throw AdapterExecutionError(.policyBlocked, "ephemeral agent requires a supported resolved output schema")
    }
    return schema
  }

  static func privateFailure(_ error: Error) -> AdapterExecutionError {
    let source = error as? AdapterExecutionError
    return .init(source?.code ?? .providerError, "ephemeral agent execution failed",
      isRetryable: source?.isRetryable, retryAfter: source?.retryAfter)
  }

  /// Called only inside the selected container. No credential is materialized
  /// in the controller's HOME/session/artifact directories.
  private static func prepareEphemeralHome(_ request: SandboxNodeRequest) throws {
    let credentials = request.credentials ?? []
    guard request.ephemeralHome == true else {
      guard credentials.isEmpty else { throw AdapterExecutionError(.policyBlocked, "runtime credentials require an ephemeral sandbox") }
      return
    }
    try preparePrivateHome(credentials: credentials)
  }

  static func preparePrivateHome(credentials: [SandboxRuntimeCredential]) throws {
    let options = WorkflowExecutionSandbox(backend: .container, ephemeralHome: true,
      credentialEnvironment: Dictionary(uniqueKeysWithValues: credentials.enumerated().map { ("CREDENTIAL_\($0.offset)", $0.element.homePath) }))
    try options.validate()
    guard let path = ProcessInfo.processInfo.environment["HOME"],
          path.hasPrefix("/tmp/riela-private-"), URL(fileURLWithPath: path).lastPathComponent == "home",
          URL(fileURLWithPath: path).standardizedFileURL.path == path else {
      throw AdapterExecutionError(.policyBlocked, "ephemeral sandbox HOME is invalid")
    }
    let home = URL(fileURLWithPath: path)
    let root = home.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    for credential in credentials {
      guard !credential.value.isEmpty, credential.value.utf8.count <= 1_000_000 else {
        throw AdapterExecutionError(.policyBlocked, "ephemeral sandbox credential is invalid")
      }
      let destination = home.appendingPathComponent(credential.homePath)
      try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try Data(credential.value.utf8).write(to: destination, options: .withoutOverwriting)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
  }

  static func sessionKey(_ input: AdapterExecutionInput, inheriting: Bool = false) -> AgentGatewaySessionKey? {
    guard let identity = input.executionIdentity else { return nil }
    return .init(workflowRunId: identity.workflowRunId, workflowSessionId: identity.workflowSessionId,
      stepId: inheriting ? (input.sessionPolicy?.inheritFromStepId ?? identity.stepId) : identity.stepId)
  }

  private static func readRequest() throws -> SandboxNodeRequest {
    var bytes = Data()
    while let chunk = try FileHandle.standardInput.read(upToCount: 64 * 1024), !chunk.isEmpty {
      bytes.append(chunk)
      guard bytes.count <= BuiltinAddonContainerRequest.maximumRecordBytes else {
        throw AdapterExecutionError(.invalidInput, "isolated node request exceeds the size limit")
      }
    }
    return try WorkerJSONLInput.decode(SandboxNodeRequest.self, from: bytes,
      framingMessage: "isolated node worker requires one JSONL request")
  }
}

final class SandboxNodeRecordWriter: @unchecked Sendable {
  private let lock = NSLock()
  private var firstFailure: AdapterExecutionError?
  var failure: AdapterExecutionError? { lock.withLock { firstFailure } }

  func emit(_ record: SandboxNodeRecord) {
    lock.withLock {
      do {
        let bytes = try JSONEncoder().encode(record)
        guard bytes.count <= BuiltinAddonContainerRequest.maximumRecordBytes else {
          throw AdapterExecutionError(.invalidOutput, "isolated node output record exceeds the size limit")
        }
        FileHandle.standardOutput.write(bytes)
        FileHandle.standardOutput.write(Data([10]))
      } catch {
        firstFailure = .init(.invalidOutput, "isolated node could not encode its output record")
      }
    }
  }
}
