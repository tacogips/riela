import Foundation
import RielaAdapters
import RielaCore

actor SandboxingNodeAdapter: NodeAdapter {
  let primary: any NodeAdapter
  let environment: [String: String]
  let workingDirectory: String?
  let supervisorMode: Bool
  let runner: any LocalProcessRunning
  var directoryParent: URL?
  private var sessions: [SandboxSessionKey: SandboxSession] = [:]

  init(primary: any NodeAdapter, environment: [String: String], workingDirectory: String?, supervisorMode: Bool = false,
       runner: any LocalProcessRunning = FoundationLocalProcessRunner(), directoryParent: URL? = nil) {
    self.primary = primary
    self.environment = environment
    self.workingDirectory = workingDirectory
    self.supervisorMode = supervisorMode
    self.runner = runner
    self.directoryParent = directoryParent
  }

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    guard let options = input.node.sandbox else { return try await primary.execute(input, context: context) }
    try options.validate()
    if options.ephemeralHome, input.sessionPolicy?.mode == .reuse {
      throw AdapterExecutionError(.policyBlocked, "ephemeral sandbox cannot reuse a vendor session")
    }
    if options.ephemeralHome, input.node.output?.jsonSchema == nil {
      throw AdapterExecutionError(.policyBlocked, "ephemeral agents require an explicit resolved output schema")
    }
    let backend = try resolveNodeExecutionBackend(input.node)
    guard [.codexAgent, .claudeCodeAgent, .cursorCliAgent, .officialOpenAISDK, .officialAnthropicSDK,
      .officialGeminiSDK, .officialCursorSDK].contains(backend) else {
      throw AdapterExecutionError(.policyBlocked, "sandboxed node requires a vendor CLI or HTTP SDK backend")
    }
    let workspace = URL(fileURLWithPath: input.node.workingDirectory ?? workingDirectory ?? FileManager.default.currentDirectoryPath,
      isDirectory: true).standardizedFileURL
    var boundaryOptions = options
    boundaryOptions.admission = nil  // Admission tuning is not isolation policy.
    let boundary = SandboxSessionBoundary(options: boundaryOptions, workspace: workspace.path, environment: input.agentEnvironment,
      provider: input.node.provider, baseURL: input.node.baseURL, apiKeyEnvironment: input.node.apiKeyEnvironment)
    let previous = input.sessionPolicy?.mode == .reuse
      ? SandboxNodeWorker.sessionKey(input, inheriting: true).flatMap { sessions[.init(backend: backend, identity: $0)] } : nil
    if let previous, previous.boundary != boundary {
      throw AdapterExecutionError(.policyBlocked, "sandbox session reuse cannot change provider, credentials, environment, or isolation policy")
    }
    let launcher = ExecutionSandboxLauncher(environment: environment)
    let executable = try launcher.workerExecutable()
    var workerInput = input
    workerInput.node.sandbox = nil
    workerInput.node.executionBackend = backend
    if options.ephemeralHome { workerInput.node.workingDirectory = "/tmp" }
    var credentials: [SandboxRuntimeCredential] = []
    for name in options.credentialEnvironment.keys.sorted() {
      guard input.agentEnvironment[name] == nil else {
        throw AdapterExecutionError(.policyBlocked, "file credentials must not also be passed as agent environment bindings")
      }
      guard let value = environment[name], !value.isEmpty, value.utf8.count <= 1_000_000 else {
        throw AdapterExecutionError(.policyBlocked, "selected sandbox runtime credential is unavailable or oversized")
      }
      credentials.append(.init(homePath: options.credentialEnvironment[name]!, value: value))
    }
    let request = SandboxNodeRequest(capabilities: SandboxNodeRequest.requiredCapabilities(
        ephemeralHome: options.ephemeralHome, output: workerInput.node.output),
      input: workerInput, deadline: context.deadline,
      previousVendorSessionId: previous?.vendorSessionId, supervisorMode: supervisorMode,
      ephemeralHome: options.ephemeralHome, credentials: credentials)
    let encoded = try JSONEncoder().encode(request)
    guard encoded.count <= BuiltinAddonContainerRequest.maximumRecordBytes, let stdin = String(data: encoded, encoding: .utf8) else {
      throw AdapterExecutionError(.invalidInput, "isolated node request exceeds the size limit")
    }
    // Wait for a pool slot only after every static refusal above; the lease
    // then covers directory creation, container start, exec and removal.
    return try await SandboxExecutionAdmission.withLease(options.admission, environment: environment, deadline: context.deadline) {
      let sessionDirectory = try previous?.directory ?? SandboxExecutionDirectory(parent: directoryParent ?? FileManager.default.temporaryDirectory)
      let directory = try SandboxExecutionDirectory(parent: directoryParent ?? FileManager.default.temporaryDirectory)
      defer { withExtendedLifetime(directory) {} }
      let configuration = try launcher.process(executable: executable, arguments: [SandboxNodeWorker.command], workspace: workspace,
        options: launcher.workerOptions(options, executable: executable), directory: directory,
        explicitEnvironment: options.ephemeralHome ? [:] : input.agentEnvironment, containerExecutable: "/opt/riela/riela",
        homeDirectory: sessionDirectory.root.appendingPathComponent("home"))
      let records = SandboxNodeRecordCollector(privateOutput: options.ephemeralHome)
      let stream = AsyncStream<AdapterBackendEvent>.makeStream()
      let eventConsumer = Task {
        for await event in stream.stream { await context.backendEventHandler?(event) }
      }
      let result: LocalProcessResult
      do {
        if options.ephemeralHome {
          result = try await EphemeralContainerNodeProcess(runner: runner).run(
            configuration: configuration, stdin: stdin + "\n", deadline: context.deadline) { event in
              guard event.stream == .stdout else { return }
              if let record = records.accept(event.line) { stream.continuation.yield(record) }
            }
        } else if let streamingRunner = runner as? any LocalProcessEventStreaming {
          result = try await streamingRunner.run(configuration: configuration, stdin: stdin + "\n", deadline: context.deadline) { event in
            guard event.stream == .stdout else { return }
            if let record = records.accept(event.line) { stream.continuation.yield(record) }
          }
        } else {
          result = try await runner.run(configuration: configuration, stdin: stdin + "\n", deadline: context.deadline)
          for line in result.stdout.split(whereSeparator: \.isNewline) {
            if let event = records.accept(String(line)) { stream.continuation.yield(event) }
          }
        }
      } catch {
        stream.continuation.finish()
        await eventConsumer.value
        throw error
      }
      stream.continuation.finish()
      await eventConsumer.value
      guard result.terminationStatus == 0 else {
        throw isolatedWorkerExitError(status: result.terminationStatus, deadline: context.deadline,
          subject: "selected sandbox worker")
      }
      let terminal = try records.result()
      if let session = terminal.vendorSessionId, let key = SandboxNodeWorker.sessionKey(input) {
        sessions[.init(backend: backend, identity: key)] = .init(vendorSessionId: session, directory: sessionDirectory, boundary: boundary)
      }
      if let failure = terminal.failure { throw try failure.executionError() }
      if terminal.kind == .rejected, let reason = terminal.rejection {
        // The runner's maxValidationAttempts loop retries only this error type.
        throw WorkflowPublicationError.validationRejected(options.ephemeralHome ? SandboxNodeWorker.privateRejectionMessage : reason)
      }
      guard let output = terminal.output else { throw AdapterExecutionError(.invalidOutput, "isolated node returned no output") }
      guard options.ephemeralHome else { return output }
      // The guest already enforced these; re-check so a misbehaving guest cannot
      // use routing labels or vendor metadata as a side channel.
      guard SandboxNodeWorker.privateRoutingIsBounded(output.when), output.promptText.isEmpty,
            output.usage?.providerRaw.isEmpty ?? true,
            SandboxNodeWorker.boundedPrivateMetadata(output.provider) != nil,
            SandboxNodeWorker.boundedPrivateMetadata(output.model) != nil else {
        throw AdapterExecutionError(.invalidOutput, "isolated node returned invalid result metadata")
      }
      return output
    }
  }

  func workflowRunDidEnd(_ context: WorkflowRunLifecycleContext) async {
    sessions = sessions.filter { $0.key.identity.workflowRunId != context.workflowRunId }
    await primary.workflowRunDidEnd(context)
  }
}

/// One mapping for "an isolated worker exited non-zero" across the sandboxed
/// node and private-workflow hosts. Worker exit text never carries guest data.
func isolatedWorkerExitError(status: Int32, deadline: Date?, subject: String,
                             recognizesGuestRefusal: Bool = false) -> AdapterExecutionError {
  if recognizesGuestRefusal, status == PrivateWorkflowWorker.guestRefusalStatus {
    return .init(.policyBlocked, "private worker refused the guest identity or resource limits")
  }
  if let deadline, deadline <= Date() {
    return .init(.timeout, "\(subject) exceeded its deadline")
  }
  return .init(.providerError, "\(subject) exited with status \(status)")
}

private struct SandboxSessionKey: Hashable {
  var backend: NodeExecutionBackend
  var identity: AgentGatewaySessionKey
}

private struct SandboxSession {
  var vendorSessionId: String
  var directory: SandboxExecutionDirectory
  var boundary: SandboxSessionBoundary
}

private struct SandboxSessionBoundary: Equatable {
  var options: WorkflowExecutionSandbox
  var workspace: String
  var environment: [String: String]
  var provider: AgentProviderConfiguration?
  var baseURL: String?
  var apiKeyEnvironment: String?
}

final class SandboxNodeRecordCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var terminal: SandboxNodeRecord?
  private var failure: AdapterExecutionError?
  private let privateOutput: Bool

  init(privateOutput: Bool = false) { self.privateOutput = privateOutput }

  func accept(_ line: String) -> AdapterBackendEvent? {
    lock.withLock {
      guard failure == nil else { return nil }
      do {
        guard line.utf8.count <= BuiltinAddonContainerRequest.maximumRecordBytes,
              let bytes = line.data(using: .utf8), terminal == nil else { throw invalid() }
        let record = try JSONDecoder().decode(SandboxNodeRecord.self, from: bytes)
        guard record.version == SandboxNodeRecord.currentVersion else {
          throw record.version < SandboxNodeRecord.currentVersion ? unsupportedVersion() : invalid()
        }
        guard !privateOutput || record.vendorSessionId == nil else { throw invalid() }
        switch record.kind {
        case .event:
          guard !privateOutput else { throw invalid() }
          guard let event = record.event, record.output == nil, record.failure == nil, record.rejection == nil,
                record.vendorSessionId == nil else { throw invalid() }
          return event
        case .result:
          guard record.output != nil, record.failure == nil, record.event == nil, record.rejection == nil else { throw invalid() }
        case .failure:
          guard record.failure != nil, record.output == nil, record.event == nil, record.rejection == nil else { throw invalid() }
        case .rejected:
          guard let rejection = record.rejection, !rejection.isEmpty,
                rejection.utf8.count <= SandboxNodeRecord.maximumRejectionBytes,
                !privateOutput || rejection == SandboxNodeWorker.privateRejectionMessage,
                record.output == nil, record.failure == nil, record.event == nil else { throw invalid() }
        }
        terminal = record
      } catch let error as AdapterExecutionError where error == unsupportedVersion() {
        failure = error
      } catch { failure = invalid() }
      return nil
    }
  }

  func result() throws -> SandboxNodeRecord {
    try lock.withLock {
      if let failure { throw failure }
      guard let terminal else { throw invalid() }
      return terminal
    }
  }

  private func invalid() -> AdapterExecutionError { .init(.invalidOutput, "isolated node returned invalid worker records") }
  private func unsupportedVersion() -> AdapterExecutionError {
    .init(.policyBlocked, "isolated worker uses an older record protocol; update the worker image")
  }
}
