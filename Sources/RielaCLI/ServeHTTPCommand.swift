import Foundation
import RielaCore
import RielaServer

struct ServeHTTPCommand: Sendable {
  typealias ReadyHandler = @Sendable (String) -> Void

  static func isLongRunningInvocation(_ arguments: [String]) -> Bool {
    guard case let .scoped(command) = try? RielaArgumentParser().parse(arguments) else {
      return false
    }
    return command.kind == .serve && command.options.command == nil
  }

  func run(arguments: [String], onReady: @escaping ReadyHandler) async -> CLICommandResult {
    guard case let .scoped(command) = try? RielaArgumentParser().parse(arguments),
          command.kind == .serve,
          command.options.command == nil else {
      return CLICommandResult(exitCode: .usage, stderr: "long-running serve requires bare `riela serve`")
    }
    do {
      let parsed = try ParsedParityOptions(command.options.arguments)
      return try await run(command: command, parsed: parsed, onReady: onReady)
    } catch let error as CLIUsageError {
      return failure(error.message, output: command.options.output, options: command.options)
    } catch {
      return failure("\(error)", output: command.options.output, options: command.options)
    }
  }

  private func run(
    command: ScopedCommand,
    parsed: ParsedParityOptions,
    onReady: @escaping ReadyHandler
  ) async throws -> CLICommandResult {
    let host = parsed.host ?? "127.0.0.1"
    let requestedPort = parsed.port ?? 8787
    let configuration = RielaServerConfiguration(
      host: host,
      port: requestedPort,
      noteAPIEnabled: parsed.noteAPIEnabled,
      noteRoot: parsed.noteAPIEnabled ? resolvedServeNoteRoot(parsed: parsed) : nil
    )
    let listenerHandle = try await inProcessListener(configuration: configuration)
    let adapter = DeterministicServerHTTPAdapter(
      routeHandler: listenerHandle.routeHandler,
      context: serveRequestContext(parsed: parsed)
    )
    let server = RielaLocalHTTPServer(routeHandler: adapter)
    let boundPort = try await server.start(host: host, port: requestedPort)
    let endpoint = "http://\(host):\(boundPort)"
    let readyResult = ScopedParityCommandResult(
      scope: "serve",
      command: nil,
      target: nil,
      status: "running",
      records: readyRecords(
        endpoint: endpoint,
        noteAPIEnabled: parsed.noteAPIEnabled,
        registrationChallenge: listenerHandle.registrationChallenge
      )
    )
    let rendered = try render(readyResult, options: command.options) { result in
      result.records.joined(separator: "\n") + "\n"
    }
    onReady(rendered.stdout.hasSuffix("\n") ? rendered.stdout : rendered.stdout + "\n")

    do {
      try await Task.sleep(nanoseconds: .max)
    } catch is CancellationError {
      // SIGINT and SIGTERM cancel the entry-point task.
    }
    await server.stop()
    try await listenerHandle.shutdown()
    return CLICommandResult(exitCode: .success)
  }

  private func inProcessListener(
    configuration: RielaServerConfiguration
  ) async throws -> InProcessWorkflowServeListenerHandle {
    let listener = try await InProcessWorkflowServeListenerFactory().startListener(
      for: WorkflowServeResolvedWorkflow(workflowId: "cli-serve", selectedIdentity: "cli-serve"),
      request: WorkflowServeStartRequest(selection: .scopedName("cli-serve"), server: configuration),
      generationId: "cli-serve"
    )
    guard let inProcessListener = listener as? InProcessWorkflowServeListenerHandle else {
      throw CLIUsageError("serve requires the in-process route listener")
    }
    return inProcessListener
  }

  private func readyRecords(
    endpoint: String,
    noteAPIEnabled: Bool,
    registrationChallenge: NoteAPIRegistrationChallenge?
  ) -> [String] {
    var records = ["endpoint=\(endpoint)", "noteAPIEnabled=\(noteAPIEnabled)"]
    if let registrationChallenge {
      records.append("registrationURL=\(registrationChallenge.registrationURL)")
    }
    return records
  }
}

func resolvedServeNoteRoot(parsed: ParsedParityOptions) -> String {
  let raw = parsed.noteRoot
    ?? CLIRuntimeEnvironment.mergedProcessEnvironment()["RIELA_NOTE_ROOT"].flatMap { $0.isEmpty ? nil : $0 }
    ?? "\(NSHomeDirectory())/.riela/note"
  return (raw as NSString).expandingTildeInPath
}

func serveRequestContext(parsed: ParsedParityOptions) -> ServerRequestContext {
  ServerRequestContext(inheritedEnvironment: parsed.sessionStore.map { ["RIELA_MANAGER_SESSION_ID": $0] } ?? [:])
}
