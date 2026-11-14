import Foundation
import RielaAdapters
import RielaCore

struct SandboxNodeRequest: Codable, Sendable {
  var version = 1
  var input: AdapterExecutionInput
  var deadline: Date?
  var previousVendorSessionId: String?
  var supervisorMode: Bool
  var ephemeralHome: Bool?
  var credentials: [SandboxRuntimeCredential]?
}

struct SandboxRuntimeCredential: Codable, Sendable {
  var homePath: String
  var value: String
}

struct SandboxNodeRecord: Codable, Sendable {
  enum Kind: String, Codable, Sendable { case event, result, failure }
  var version = 1
  var kind: Kind
  var event: AdapterBackendEvent?
  var output: AdapterExecutionOutput?
  var failure: BuiltinAddonContainerFailure?
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
      let nativeSchema = request.input.node.output?.nativeStructuredOutput == true
      let legacyVersion = request.version == 1 && request.ephemeralHome != true && !nativeSchema
      let privateVersion = request.version == 2 && request.ephemeralHome == true && !nativeSchema
      let structuredVersion = request.version == 3 && nativeSchema
      guard legacyVersion || privateVersion || structuredVersion, request.input.node.sandbox == nil else {
        throw AdapterExecutionError(.invalidInput, "invalid isolated node worker request")
      }
      if request.ephemeralHome == true { _ = try privateContract(request.input.node.output) }
      try prepareEphemeralHome(request)
      let sessionStore = AgentGatewaySessionStore()
      if let previous = request.previousVendorSessionId,
         request.input.sessionPolicy?.mode == .reuse, let key = sessionKey(request.input, inheriting: true) {
        sessionStore.setSessionId(previous, for: key)
      }
      let adapter = AgentGatewayNodeAdapter(environment: ProcessInfo.processInfo.environment,
        codexSupervisorModeEnabled: request.supervisorMode,
        defaultWorkingDirectory: FileManager.default.currentDirectoryPath, sessionStore: sessionStore)
      let output: AdapterExecutionOutput
      do {
        let streamingHandler: AdapterBackendEventHandler = { event in
          writer.emit(.init(kind: .event, event: event))
        }
        let result = try await adapter.execute(request.input, context: .init(deadline: request.deadline,
          backendEventHandler: request.ephemeralHome == true ? nil : streamingHandler))
        output = request.ephemeralHome == true ? try privateOutput(result, contract: request.input.node.output) : result
        if let failure = writer.failure { throw failure }
      } catch {
        let failure = request.ephemeralHome == true ? privateFailure(error)
          : (error as? AdapterExecutionError) ?? .init(.providerError, "isolated node worker execution failed")
        writer.emit(.init(kind: .failure, failure: .init(failure),
          vendorSessionId: request.ephemeralHome == true ? nil : sessionKey(request.input).flatMap(sessionStore.sessionId(for:))))
        return
      }
      writer.emit(.init(kind: .result, output: output,
        vendorSessionId: request.ephemeralHome == true ? nil : sessionKey(request.input).flatMap(sessionStore.sessionId(for:))))
    } catch {
      writer.emit(.init(kind: .failure, failure: .init((error as? AdapterExecutionError)
        ?? .init(.invalidInput, "invalid isolated node worker input"))))
    }
  }

  static func privateOutput(_ output: AdapterExecutionOutput, contract: NodeOutputContract?) throws -> AdapterExecutionOutput {
    let schema = try privateContract(contract)
    let accepted = try DefaultWorkflowOutputValidator().validate(
      .init(source: .adapterOutput, payload: output.payload, completionPassed: output.completionPassed),
      contract: .init(schema: schema, requiredObject: true))
    guard accepted.status == .accepted else {
      throw AdapterExecutionError(.invalidOutput, "ephemeral agent output contract rejected")
    }
    var result = output
    result.promptText = ""
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
    guard let text = String(data: bytes, encoding: .utf8), text.split(whereSeparator: \.isNewline).count == 1 else {
      throw AdapterExecutionError(.invalidInput, "isolated node worker requires one JSONL request")
    }
    return try JSONDecoder().decode(SandboxNodeRequest.self, from: bytes)
  }
}

private final class SandboxNodeRecordWriter: @unchecked Sendable {
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
