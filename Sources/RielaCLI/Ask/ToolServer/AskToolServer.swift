import ArgumentParser
import Foundation
import RielaCore
import RielaWorkflowRegistry
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct AskToolServerArguments: RielaClientFamilyArguments {
  static let verb = "tool-server"

  @Option var sessionStore: String
  @Option var workingDir: String
  @Option var conversation: String
  @Option var turn: String
  @Option var scope: String?
  @Option var redactionValues: String?
}

enum AskToolServer {
  static func run(arguments: [String]) async throws {
    try await run(
      options: AskToolServerArguments.parseCLI(arguments),
      environment: ProcessInfo.processInfo.environment,
      nextLine: { readLine() },
      write: { try FileHandle.standardOutput.write(contentsOf: $0) }
    )
  }

  static func run(
    options: AskToolServerArguments, environment: [String: String], limits: AskLimits = .standard,
    nextLine: () throws -> String?, write: (Data) throws -> Void, isolation: isolated (any Actor)? = #isolation
  ) async throws {
    guard let scope = WorkflowScope(rawValue: options.scope ?? "auto") else {
      throw CLIUsageError("Invalid --scope for ask tool-server")
    }
    let values = try options.redactionValues.map(readRedactionValues) ?? [:]
    let store = BotStore(sessionStoreRoot: canonicalRuntimeStoreRoot(sessionStoreRoot: options.sessionStore))
    let turn = try store.askConversation(id: options.conversation)?.turn
    guard turn?.turnId == options.turn, turn?.status == .running else {
      throw AskError(code: "turn_not_running", message: "Ask turn is no longer running")
    }

    // Registry providers also resolve their effective environment through this task-local snapshot.
    try await CLIRuntimeEnvironment.$captured.withValue(environment) {
      let providers = AskReadProviders.local(
        workingDirectory: options.workingDir, sessionStore: options.sessionStore, scope: scope, environment: environment
      )
      let surface = ProviderAskReadSurface(providers: providers)
      let executor = AskToolExecutor(
        store: store, surface: surface,
        proposals: AskActionProposer(
          surface: surface, store: store, environment: environment, limits: limits, additionalRedactionValues: values
        ),
        recorder: SQLiteWorkflowActivityRecorder(sessionStoreRoot: store.sessionStoreRoot),
        environment: environment, limits: limits, now: Date.init, additionalRedactionValues: values
      )
      let server = AskToolServerProtocol(executor: executor, conversationId: options.conversation, turnId: options.turn)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      while let line = try nextLine() {
        if let reply = try await server.response(to: line) {
          var data = try encoder.encode(reply)
          data.append(10)
          try write(data)
        }
      }
    }
  }

  private static func readRedactionValues(_ path: String) throws -> [String: String] {
    let unavailable = AskError(code: "redaction_values_unavailable", message: "Ask redaction values could not be read")
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw unavailable }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? file.close() }
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
      throw unavailable
    }
    do {
      guard let data = try file.readToEnd() else { throw unavailable }
      return try JSONDecoder().decode([String: String].self, from: data)
    } catch {
      throw unavailable
    }
  }
}
