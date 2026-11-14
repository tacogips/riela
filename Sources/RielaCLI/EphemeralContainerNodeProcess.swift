import Foundation
import RielaAdapters
import RielaCore

/// Keep private worker stdio out of Apple Container's persisted init logs.
/// A bounded, non-sensitive sleep owns the VM; attached exec carries the node
/// request/events. The exact owned container is removed even after cancellation.
struct EphemeralContainerNodeProcess: Sendable {
  var runner: any LocalProcessRunning

  func run(configuration: LocalProcessConfiguration, stdin: String, deadline: Date?,
           onEmptyInputRetry: (@Sendable () async -> Void)? = nil,
           outputEventHandler: @escaping @Sendable (LocalProcessOutputEvent) -> Void) async throws -> LocalProcessResult {
    let arguments = configuration.arguments
    guard let runIndex = arguments.firstIndex(of: "run"), let workerCommand = arguments.last,
          [SandboxNodeWorker.command, PrivateWorkflowWorker.command].contains(workerCommand),
          let entrypointIndex = arguments.firstIndex(of: "--entrypoint"), entrypointIndex + 1 < arguments.count - 2 else {
      throw AdapterExecutionError(.policyBlocked, "invalid ephemeral container invocation")
    }
    let prefix = Array(arguments[..<runIndex])
    let runtime = configuration.executableURL.lastPathComponent == "env"
      ? prefix.first.map { URL(fileURLWithPath: $0).lastPathComponent } : configuration.executableURL.lastPathComponent
    guard ["container", "docker", "podman"].contains(runtime) else {
      throw AdapterExecutionError(.policyBlocked, "ephemeral agents require Apple Container, Docker or Podman")
    }
    let name = "riela-agent-" + UUID().uuidString.lowercased()
    let worker = arguments[entrypointIndex + 1]
    var flags = Array(arguments[(runIndex + 1)..<(arguments.count - 2)])
    if let index = flags.firstIndex(of: "-i") { flags.remove(at: index) }
    guard let flagIndex = flags.firstIndex(of: "--entrypoint") else {
      throw AdapterExecutionError(.policyBlocked, "ephemeral agent worker entrypoint is missing")
    }
    flags[flagIndex + 1] = "/bin/sleep"
    let effectiveDeadline = deadline ?? Date().addingTimeInterval(600)
    let lifetime = String(max(1, Int(ceil(effectiveDeadline.timeIntervalSinceNow))) + 30)
    var initialize = configuration
    initialize.arguments = prefix + ["run", "-d", "--name", name, "--cap-drop", "ALL"] + flags
      + [arguments[arguments.count - 2], lifetime]
    var execute = configuration
    execute.arguments = prefix + ["exec", "-i", name, worker, workerCommand]
    var remove = configuration
    remove.arguments = prefix + [runtime == "container" ? "delete" : "rm", "--force", name]
    let result: LocalProcessResult
    do {
      let initialized = try await runner.run(configuration: initialize, stdin: "", deadline: effectiveDeadline)
      guard initialized.terminationStatus == 0 else {
        throw AdapterExecutionError(.policyBlocked, "ephemeral agent container initialization failed")
      }
      var attached = try await attach(execute, stdin: stdin, deadline: effectiveDeadline, handler: outputEventHandler)
      if !stdin.isEmpty, Self.refusedEmptyInput(attached, worker: workerCommand) {
        try Task.checkCancellation()
        guard effectiveDeadline > Date() else { throw AdapterExecutionError(.timeout, "private input transport deadline expired") }
        await onEmptyInputRetry?()
        // This exact worker refusal happens before request decoding, HOME
        // setup or provider/model execution. Reattach once; never retry a
        // model failure, output rejection or an ambiguous transport outcome.
        attached = try await attach(execute, stdin: stdin, deadline: effectiveDeadline, handler: outputEventHandler)
      }
      result = attached
      // Private workers emit only terminal stdout. Withhold the pre-request
      // refusal so a successful reattach never emits two terminal records.
      for line in result.stdout.split(separator: "\n") {
        outputEventHandler(.init(stream: .stdout, line: String(line)))
      }
    } catch {
      await cleanup(remove)
      throw error
    }
    await cleanup(remove)
    return result
  }

  private func attach(_ configuration: LocalProcessConfiguration, stdin: String, deadline: Date,
                      handler: @escaping @Sendable (LocalProcessOutputEvent) -> Void) async throws -> LocalProcessResult {
    if let streaming = runner as? any LocalProcessEventStreaming {
      return try await streaming.run(configuration: configuration, stdin: stdin, deadline: deadline) { event in
        if event.stream == .stderr { handler(event) }
      }
    }
    let result = try await runner.run(configuration: configuration, stdin: stdin, deadline: deadline)
    for line in result.stderr.split(separator: "\n") { handler(.init(stream: .stderr, line: String(line))) }
    return result
  }

  static func refusedEmptyInput(_ result: LocalProcessResult, worker: String) -> Bool {
    let expected: String
    switch worker {
    case SandboxNodeWorker.command: expected = WorkerJSONLInput.nodeEmptyMessage
    case PrivateWorkflowWorker.command: expected = WorkerJSONLInput.privateEmptyMessage
    default: return false
    }
    guard result.terminationStatus == 0, !result.stdoutInvalidUTF8, result.stdout.utf8.count <= 4096,
      result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      result.stdout.split(separator: "\n").count == 1,
      let record = try? JSONDecoder().decode(SandboxNodeRecord.self, from: Data(result.stdout.utf8)),
      record.version == SandboxNodeRecord.currentVersion, record.kind == .failure,
      record.output == nil, record.event == nil, record.rejection == nil, record.vendorSessionId == nil,
      let failure = record.failure, failure.code == .invalidInput, failure.message == expected,
      failure.isRetryable == nil, failure.retryAfterSeconds == nil else { return false }
    return true
  }

  private func cleanup(_ configuration: LocalProcessConfiguration) async {
    let runner = runner
    await Task.detached {
      _ = try? await runner.run(configuration: configuration, stdin: "", deadline: Date().addingTimeInterval(10))
    }.value
  }
}
