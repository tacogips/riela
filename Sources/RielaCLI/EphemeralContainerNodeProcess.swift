import Foundation
import RielaAdapters
import RielaCore

/// Keep private worker stdio out of Apple Container's persisted init logs.
/// A bounded, non-sensitive sleep owns the VM; attached exec carries the node
/// request/events. The exact owned container is removed even after cancellation.
struct EphemeralContainerNodeProcess: Sendable {
  var runner: any LocalProcessRunning

  func run(configuration: LocalProcessConfiguration, stdin: String, deadline: Date?,
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
      if let streaming = runner as? any LocalProcessEventStreaming {
        result = try await streaming.run(configuration: execute, stdin: stdin, deadline: effectiveDeadline,
          outputEventHandler: outputEventHandler)
      } else {
        result = try await runner.run(configuration: execute, stdin: stdin, deadline: effectiveDeadline)
        for line in result.stdout.split(whereSeparator: \.isNewline) {
          outputEventHandler(.init(stream: .stdout, line: String(line)))
        }
      }
    } catch {
      await cleanup(remove)
      throw error
    }
    await cleanup(remove)
    return result
  }

  private func cleanup(_ configuration: LocalProcessConfiguration) async {
    let runner = runner
    await Task.detached {
      _ = try? await runner.run(configuration: configuration, stdin: "", deadline: Date().addingTimeInterval(10))
    }.value
  }
}
