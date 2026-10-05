import ArgumentParser
import Foundation
import RielaCore
import RielaGraphQL
import RielaWork

struct TaskServeTakeoverOptions: Sendable {
  var takeover: Bool
  var endpoint: String?
  var pollIntervalMs: Int
  var once: Bool
  var traits: [HostTrait]
  var store: TaskStoreOptions
  var auth: TaskRemoteAuth
}

struct TaskServeTakeover {
  var transport: any TaskHandoverGraphQLTransporting = URLSessionTaskHandoverGraphQLTransport(session: .shared)
  /// Builds the local-mode dispatcher; the default is the production `TaskDispatch`.
  var localDispatch: @Sendable (TaskRunSignalState?) -> TaskDispatch = { TaskDispatch(signalState: $0) }

  func run(_ arguments: [String], signalState: TaskRunSignalState?) async -> CLICommandResult {
    do {
      let options = try Self.parse(arguments)
      guard options.takeover else { throw CLIUsageError("task serve supports --takeover only until Work Runtime P3") }
      guard options.pollIntervalMs > 0 else { throw CLIUsageError("--poll-interval-ms must be positive") }
      while !Task.isCancelled && signalState?.isRequested != true {
        let candidates = try await awaiting(options)
        if let candidate = candidates.filter({ !$0.needsAnswer }).sorted(by: { $0.createdAt < $1.createdAt }).first {
          if let endpoint = options.endpoint {
            let result = await TaskRemoteTakeover(transport: transport).run(TaskRemoteTakeoverOptions(
              taskId: candidate.taskId, handoverId: candidate.handoverId, endpoint: endpoint,
              auth: options.auth, traits: options.traits, workingDirectory: options.store.workingDirectory,
              cloneInto: nil, sessionStore: options.store.sessionStore, scope: options.store.scope, output: .json
            ))
            if Task.isCancelled || signalState?.isRequested == true { return CLICommandResult(exitCode: .success) }
            if result.exitCode != .success && result.exitCode != .suspended { return result }
          } else {
            let taskId = TaskID(candidate.taskId)
            guard let located = try TaskCommandRunner().locateTask(taskId, in: options.store) else {
              throw WorkStoreError("task '\(candidate.taskId)' was not found")
            }
            // Dispatch only admits a takeover once a takeover decision exists (as `task takeover` records one);
            // requestTakeover is idempotent while a takeover reservation is already pending.
            _ = try TaskHandoverRuntime(located: located, options: options.store).requestTakeover(
              taskId: taskId, traits: options.traits, producer: .policy(rule: "task-serve-takeover")
            )
            let result = await localDispatch(signalState).run(
              taskId: candidate.taskId, options: options.store, dryRun: false, output: .json,
              localTraits: options.traits, packetOverride: nil
            )
            if Task.isCancelled || signalState?.isRequested == true { return CLICommandResult(exitCode: .success) }
            if result.exitCode != .success && result.exitCode != .suspended { return result }
          }
        }
        if options.once { return CLICommandResult(exitCode: .success) }
        do { try await Task.sleep(for: .milliseconds(options.pollIntervalMs)) } catch { break }
      }
      return CLICommandResult(exitCode: .success)
    } catch let error as CLIUsageError {
      return CLICommandResult(exitCode: .usage, stderr: error.message)
    } catch {
      return CLICommandResult(exitCode: .failure, stderr: String(describing: error))
    }
  }

  private func awaiting(_ options: TaskServeTakeoverOptions) async throws -> [GraphQLTaskHandoverSummary] {
    let traits = options.traits.map { $0.rawValue }
    if let endpoint = options.endpoint {
      let query = """
      query TasksAwaitingHandover($traits: [String!]) {
        tasksAwaitingHandover(traits: $traits) {
          tasks { taskId handoverId reasonKind requiredTraits needsAnswer questionText createdAt }
          errors { code message }
        }
      }
      """
      let response = try await transport.execute(endpoint: endpoint, query: query,
        variables: ["traits": .array(traits.map(JSONValue.string))], auth: options.auth)
      guard let value = response["tasksAwaitingHandover"] else { throw WorkStoreError("GraphQL response omitted tasksAwaitingHandover") }
      let payload = try JSONCanonical.decoder().decode(GraphQLTasksAwaitingHandoverPayload.self, from: JSONEncoder().encode(value))
      if let error = payload.errors.first { throw WorkStoreError(error.message) }
      return payload.tasks
    }
    let roots = TaskCommandRunner().storeRoots(options.store)
    let root = roots.first ?? canonicalRuntimeStoreRoot(sessionStoreRoot: options.store.sessionStore ?? options.store.workingDirectory)
    return try WorkStore(rootDirectory: root).tasksAwaitingHandover(traits: options.traits)
      .map { row in GraphQLTaskHandoverSummary(
        taskId: row.taskId.rawValue, handoverId: row.handoverId.rawValue, reasonKind: row.reasonKind,
        requiredTraits: row.requiredTraits.map(\.rawValue), needsAnswer: row.needsAnswer,
        questionText: row.questionText, createdAt: ISO8601DateFormatter().string(from: row.createdAt)
      ) }
  }

  private static func parse(_ arguments: [String]) throws -> TaskServeTakeoverOptions {
    let parsed = try ParsedTaskServeTakeoverOptions.parseCLI(arguments)
    guard let scope = WorkflowScope(rawValue: parsed.scope), scope != .direct else {
      throw CLIUsageError("invalid --scope value '\(parsed.scope)'; expected auto, project, or user")
    }
    let traits = try (parsed.traits ?? "").split(separator: ",", omittingEmptySubsequences: false).filter { !$0.isEmpty }.map { raw -> HostTrait in
      guard let trait = HostTrait(rawValue: String(raw)) else { throw CLIUsageError("unknown host trait '\(raw)'") }
      return trait
    }
    let environment = CLIRuntimeEnvironment.mergedProcessEnvironment()
    let authTokenEnv = parsed.authTokenEnv ?? "RIELA_API_KEY"
    return TaskServeTakeoverOptions(
      takeover: parsed.takeover, endpoint: parsed.endpoint, pollIntervalMs: parsed.pollIntervalMs,
      once: parsed.once, traits: Array(Set(traits)).sorted(),
      store: TaskStoreOptions(scope: scope, workingDirectory: parsed.workingDirectory, sessionStore: parsed.sessionStore),
      auth: TaskRemoteAuth(token: parsed.authToken ?? environment[authTokenEnv],
        managerSessionId: parsed.managerSessionId ?? environment["RIELA_MANAGER_SESSION_ID"])
    )
  }
}

private struct ParsedTaskServeTakeoverOptions: RielaClientFamilyArguments {
  @Flag var takeover = false
  @Option var endpoint: String?
  @Option var pollIntervalMs = 5_000
  @Flag var once = false
  @Option var traits: String?
  @Option var scope = "auto"
  @Option(name: [.customLong("working-dir"), .customLong("working-directory")]) var workingDirectory = FileManager.default.currentDirectoryPath
  @Option var sessionStore: String?
  @Option var authToken: String?
  @Option var authTokenEnv: String?
  @Option var managerSessionId: String?
}
