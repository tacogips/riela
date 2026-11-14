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
    let backend = try resolveNodeExecutionBackend(input.node)
    guard [.codexAgent, .claudeCodeAgent, .cursorCliAgent, .officialOpenAISDK, .officialAnthropicSDK,
      .officialGeminiSDK, .officialCursorSDK].contains(backend) else {
      throw AdapterExecutionError(.policyBlocked, "sandboxed node requires a vendor CLI or HTTP SDK backend")
    }
    let workspace = URL(fileURLWithPath: input.node.workingDirectory ?? workingDirectory ?? FileManager.default.currentDirectoryPath,
      isDirectory: true).standardizedFileURL
    let boundary = SandboxSessionBoundary(options: options, workspace: workspace.path, environment: input.agentEnvironment,
      provider: input.node.provider, baseURL: input.node.baseURL, apiKeyEnvironment: input.node.apiKeyEnvironment)
    let previous = input.sessionPolicy?.mode == .reuse
      ? SandboxNodeWorker.sessionKey(input, inheriting: true).flatMap { sessions[.init(backend: backend, identity: $0)] } : nil
    if let previous, previous.boundary != boundary {
      throw AdapterExecutionError(.policyBlocked, "sandbox session reuse cannot change provider, credentials, environment, or isolation policy")
    }
    let sessionDirectory = try previous?.directory ?? SandboxExecutionDirectory(parent: directoryParent ?? FileManager.default.temporaryDirectory)
    let directory = try SandboxExecutionDirectory(parent: directoryParent ?? FileManager.default.temporaryDirectory)
    defer { withExtendedLifetime(directory) {} }
    let launcher = ExecutionSandboxLauncher(environment: environment)
    let executable = try launcher.workerExecutable()
    var workerInput = input
    workerInput.node.sandbox = nil
    workerInput.node.executionBackend = backend
    let request = SandboxNodeRequest(input: workerInput, deadline: context.deadline,
      previousVendorSessionId: previous?.vendorSessionId, supervisorMode: supervisorMode)
    let encoded = try JSONEncoder().encode(request)
    guard encoded.count <= BuiltinAddonContainerRequest.maximumRecordBytes, let stdin = String(data: encoded, encoding: .utf8) else {
      throw AdapterExecutionError(.invalidInput, "isolated node request exceeds the size limit")
    }
    let configuration = try launcher.process(executable: executable, arguments: [SandboxNodeWorker.command], workspace: workspace,
      options: launcher.workerOptions(options, executable: executable), directory: directory,
      explicitEnvironment: input.agentEnvironment, containerExecutable: "/opt/riela/riela",
      homeDirectory: sessionDirectory.root.appendingPathComponent("home"))
    let records = SandboxNodeRecordCollector()
    let stream = AsyncStream<AdapterBackendEvent>.makeStream()
    let eventConsumer = Task {
      for await event in stream.stream { await context.backendEventHandler?(event) }
    }
    let result: LocalProcessResult
    do {
      if let streamingRunner = runner as? any LocalProcessEventStreaming {
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
      throw AdapterExecutionError(.policyBlocked, "selected sandbox worker failed with exit code \(result.terminationStatus)")
    }
    let terminal = try records.result()
    if let session = terminal.vendorSessionId, let key = SandboxNodeWorker.sessionKey(input) {
      sessions[.init(backend: backend, identity: key)] = .init(vendorSessionId: session, directory: sessionDirectory, boundary: boundary)
    }
    if let failure = terminal.failure { throw try failure.executionError() }
    guard let output = terminal.output else { throw AdapterExecutionError(.invalidOutput, "isolated node returned no output") }
    return output
  }

  func workflowRunDidEnd(_ context: WorkflowRunLifecycleContext) async {
    sessions = sessions.filter { $0.key.identity.workflowRunId != context.workflowRunId }
    await primary.workflowRunDidEnd(context)
  }
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

private final class SandboxNodeRecordCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var terminal: SandboxNodeRecord?
  private var failure: AdapterExecutionError?

  func accept(_ line: String) -> AdapterBackendEvent? {
    lock.withLock {
      guard failure == nil else { return nil }
      do {
        guard line.utf8.count <= BuiltinAddonContainerRequest.maximumRecordBytes,
              let bytes = line.data(using: .utf8), terminal == nil else { throw invalid() }
        let record = try JSONDecoder().decode(SandboxNodeRecord.self, from: bytes)
        guard record.version == 1 else { throw invalid() }
        switch record.kind {
        case .event:
          guard let event = record.event, record.output == nil, record.failure == nil, record.vendorSessionId == nil else { throw invalid() }
          return event
        case .result:
          guard record.output != nil, record.failure == nil, record.event == nil else { throw invalid() }
        case .failure:
          guard record.failure != nil, record.output == nil, record.event == nil else { throw invalid() }
        }
        terminal = record
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
}
