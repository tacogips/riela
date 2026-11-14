import ArgumentParser
import Foundation
import RielaAppSupport
import RielaCore

private struct AppInstanceOptions: ParsableArguments {
  @Option var server: String?
  @Option var profile: String?
  @Option(name: .customLong("cwd")) var cwd = FileManager.default.currentDirectoryPath
  @Option var reason: String?
  @Option var session: String?
  @Option var workflowDefinitionDir: String?
  @Flag var interruptRunning = false
  @Flag var waitIdle = false
  @Option var timeoutSeconds: Int?
  @Option var variables: String?
  @Flag var wait = false
  @Flag var allowOverlap = false
  @Option var pollIntervalSeconds: Int = 2
  @Option var limit: Int = 20
}

struct InstanceAppCommands: Sendable {
  var transport: RielaAppAPIClient.Transport?
  var sleep: @Sendable (UInt64) async throws -> Void
  var environment: [String: String]?
  #if os(macOS)
  var probe: (@Sendable (URL) throws -> RielaAppLocalControlProbe.Outcome)?
  #endif

  #if os(macOS)
  init(transport: RielaAppAPIClient.Transport? = nil,
       sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
       environment: [String: String]? = nil,
       probe: (@Sendable (URL) throws -> RielaAppLocalControlProbe.Outcome)? = nil) {
    self.transport = transport
    self.sleep = sleep
    self.environment = environment
    self.probe = probe
  }
  #else
  init(transport: RielaAppAPIClient.Transport? = nil,
       sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
       environment: [String: String]? = nil) {
    self.transport = transport
    self.sleep = sleep
    self.environment = environment
  }
  #endif

  func run(_ options: CLICommandOptions) async -> CLICommandResult {
    do {
      guard let identity = options.target, !identity.isEmpty, identity.utf8.count <= 1024 else {
        throw CLIUsageError("instance_identity_required")
      }
      let args: AppInstanceOptions
      do {
        args = try AppInstanceOptions.parse(options.arguments)
      } catch { throw CLIUsageError(AppInstanceOptions.message(for: error)) }
      let action = options.command ?? ""
      guard ["reload", "run", "executions", "cancel"].contains(action), (1...100).contains(args.limit),
        (1...60).contains(args.pollIntervalSeconds), action == "run" || !args.allowOverlap,
        args.timeoutSeconds.map({ (1...86400).contains($0) }) ?? true else {
        throw CLIUsageError("instance_invalid_options")
      }
      let reason = args.reason?.trimmingCharacters(in: .whitespacesAndNewlines)
      if ["reload", "cancel"].contains(action), !(reason.map { (1...512).contains($0.utf8.count) } ?? false) {
        throw CLIUsageError("instance_reason_required")
      }
      if action == "cancel", args.timeoutSeconds != nil && !args.wait ||
        !(args.session.map { (1...1024).contains($0.utf8.count) } ?? true) {
        throw CLIUsageError("instance_invalid_options")
      }
      var variables: [String: Any] = [:]
      if action == "run", let reference = args.variables {
        do {
          let object = try JSONReferenceLoader().object(from: reference, workingDirectory: args.cwd)
          variables = try JSONSerialization.jsonObject(with: JSONEncoder().encode(object)) as? [String: Any] ?? [:]
        } catch { throw CLIUsageError("instance_invalid_variables") }
      }
      let environment = environment ?? CLIRuntimeEnvironment.mergedProcessEnvironment()
      let root = RielaAppAPIClient.appRoot(environment: environment)
      let profile = try RielaAppAPIClient.expectedProfile(explicit: args.profile, appRoot: root)
      let client: any RielaAppInstanceControlClient
      if let server = args.server {
        let endpoint = try RielaAppAPIClient.resolveEndpoint(server: server, appRoot: root, environment: environment)
        var http = RielaAppAPIClient(endpoint: endpoint, profile: profile)
        if let transport { http.transport = transport }
        client = RielaAppHTTPInstanceControlClient(client: http)
      } else {
        #if os(macOS)
        guard Self.localInstanceExists(identity: identity, profile: profile, root: root) else {
          throw RielaAppAPIFailure(code: "instance_not_found", status: 404, body: Data())
        }
        client = RielaAppLocalInstanceControlClient(appRoot: root,
          homeDirectory: URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory(environment: environment)), profile: profile,
          probe: probe ?? { try RielaAppLocalControlProbe.resolve(appRoot: $0) })
        #else
        throw CLIUsageError("app_server_required")
        #endif
      }
      switch action {
      case "reload":
        return try await reload(client, identity: identity, args: args, reason: reason ?? "")
      case "cancel":
        return try await cancel(client, identity: identity, args: args, reason: reason ?? "")
      case "run":
        return try await runInstance(client, identity: identity, args: args, variables: variables)
      default:
        return try await executions(client, identity: identity, limit: args.limit)
      }
    } catch let error as CLIUsageError {
      return Self.failure(error.message, exitCode: .usage)
    } catch let error as RielaAppAPIFailure {
      let hint: String
      switch error.code {
      case "app_unreachable": hint = ": start the web server in RielaApp Console > Settings > Web Config server"
      case "app_not_running": hint = ": start RielaApp, or use --server"
      case "app_channel_unavailable": hint = ": another local riela operation or App startup is in progress; retry"
      default: hint = ""
      }
      return Self.failure(error.code, exitCode: .failure, stderr: error.code + hint)
    } catch {
      return Self.failure("app_request_failed", exitCode: .failure)
    }
  }

  private static func localInstanceExists(identity: String, profile: String, root: URL) -> Bool {
    guard profile != ".", profile != "..", !profile.contains("/") else { return false }
    let url = root.appendingPathComponent("profiles", isDirectory: true)
      .appendingPathComponent(profile, isDirectory: true).appendingPathComponent("daemon-workflows.json")
    guard let data = try? Data(contentsOf: url),
      let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let preferences = state["preferences"] as? [String: Any] else { return false }
    return preferences[identity] != nil
  }

  private func reload(_ client: any RielaAppInstanceControlClient, identity: String, args: AppInstanceOptions,
                      reason: String) async throws -> CLICommandResult {
    var elapsed = 0
    let timeout = args.timeoutSeconds ?? 600
    let directory: String? = args.workflowDefinitionDir.map {
      URL(fileURLWithPath: $0, relativeTo: URL(fileURLWithPath: args.cwd, isDirectory: true)).standardizedFileURL.path
    }
    while true {
      let revision = try await client.bootstrapRevision()
      let body: [String: Any] = ["expectedProfile": client.profile, "expectedRevision": revision,
                                 "reason": reason, "workflowDirectory": directory as Any? ?? NSNull(),
                                 "interruptRunning": args.interruptRunning]
      do {
        let data = try await client.reload(identity: identity, body: body)
        let response = try JSONDecoder().decode(AppReloadResponse.self, from: data)
        return try Self.result(response, code: response.handoff == "lost" ? "reload_handoff_lost" : nil)
      } catch let failure as RielaAppAPIFailure {
        if failure.status == 409, failure.code == "instance_run_in_flight", args.waitIdle, elapsed < timeout {
          let delay = min(10, timeout - elapsed)
          try await sleep(UInt64(delay) * 1_000_000_000)
          elapsed += delay
          continue
        }
        if failure.status == 404 || failure.status == 405, failure.code != "instance_not_found" {
          throw RielaAppAPIFailure(code: "app_reload_unsupported", status: failure.status, body: Data())
        }
        if let partial = try? JSONDecoder().decode(AppReloadFailure.self, from: failure.body), partial.committed == true {
          return try Self.result(partial.sanitized(code: failure.code), code: failure.code)
        }
        throw failure
      }
    }
  }

  private func cancel(_ client: any RielaAppInstanceControlClient, identity: String, args: AppInstanceOptions,
                      reason: String) async throws -> CLICommandResult {
    _ = try await client.bootstrapRevision()
    let response: AppCancelResponse
    do {
      let data = try await client.cancel(identity: identity, sessionId: args.session, body: ["expectedProfile": client.profile, "reason": reason])
      response = try JSONDecoder().decode(AppCancelResponse.self, from: data)
    } catch let failure as RielaAppAPIFailure {
      if failure.code == "ambiguous_running_sessions" {
        let details = try? JSONDecoder().decode(AppCancelAmbiguityDetails.self, from: failure.body)
        return try Self.result(AppCancelAmbiguity(error: failure.code, exitCode: 1,
          sessionIds: details?.sessionIds ?? [], pendingRunCount: details?.pendingRunCount ?? 0), code: failure.code)
      }
      if [404, 405].contains(failure.status), !["instance_not_found", "session_not_found"].contains(failure.code) {
        throw RielaAppAPIFailure(code: "app_cancel_unsupported", status: failure.status, body: Data())
      }
      throw failure
    }
    var output = AppCancelOutput(response: response, status: nil)
    guard args.wait else { return try Self.result(output) }
    var elapsed = 0
    let timeout = args.timeoutSeconds ?? 60
    while true {
      let data = try await client.executionDetail(identity: identity, sessionId: response.sessionId)
      output.status = try JSONDecoder().decode(AppExecutionDetail.self, from: data).session.status
      if output.status == "cancelled" { return try Self.result(output) }
      if output.status == "completed" || output.status == "failed" {
        return try Self.result(output, code: "cancel_not_effective")
      }
      guard elapsed < timeout else { return try Self.result(output, code: "cancel_wait_timeout") }
      try await sleep(1_000_000_000)
      elapsed += 1
    }
  }

  private func runInstance(_ client: any RielaAppInstanceControlClient, identity: String, args: AppInstanceOptions,
                           variables: [String: Any]) async throws -> CLICommandResult {
    let revision = try await client.bootstrapRevision()
    var body: [String: Any] = ["expectedProfile": client.profile, "expectedRevision": revision,
                               "variables": variables]
    if args.allowOverlap { body["allowOverlap"] = true }
    let data: Data
    do {
      data = try await client.run(identity: identity, body: body)
    } catch let failure as RielaAppAPIFailure where failure.status == 409 && failure.code == "instance_busy" {
      guard let busy = try? JSONDecoder().decode(AppInstanceBusyFailure.self, from: failure.body),
        let sessionId = busy.error.runningSessionId else { throw failure }
      return try Self.result(AppInstanceBusyOutput(error: failure.code, sessionId: sessionId, exitCode: 1), code: failure.code)
    }
    var launch = try JSONDecoder().decode(AppLaunch.self, from: data)
    let timeout = args.timeoutSeconds ?? (args.wait ? 3600 : 60)
    var elapsed = 0
    while true {
      if launch.status == "failed" { return try Self.result(launch.output(includeError: args.wait), code: "run_failed") }
      if launch.status == "completed" || (!args.wait && launch.sessionId != nil) {
        return try Self.result(launch.output(includeError: args.wait))
      }
      guard elapsed < timeout else { return try Self.result(launch.output(includeError: args.wait), code: "run_wait_timeout") }
      let delay = min(args.pollIntervalSeconds, timeout - elapsed)
      try await sleep(UInt64(delay) * 1_000_000_000)
      elapsed += delay
      do {
        let next = try await client.launchStatus(launchId: launch.id)
        launch = try JSONDecoder().decode(AppLaunch.self, from: next)
      } catch let failure as RielaAppAPIFailure where failure.status == 404 && launch.sessionId != nil {
        let data = try await client.executionDetail(identity: identity, sessionId: launch.sessionId ?? "")
        let detail = try JSONDecoder().decode(AppExecutionDetail.self, from: data)
        launch.status = detail.session.status
      }
    }
  }

  private func executions(_ client: any RielaAppInstanceControlClient, identity: String,
                          limit: Int) async throws -> CLICommandResult {
    let data = try await client.executions(identity: identity)
    let response = try JSONDecoder().decode(AppExecutions.self, from: data)
    let result = AppExecutionsOutput(identity: identity, profile: client.profile,
      items: Array(response.items.prefix(limit)), truncated: response.truncated || response.items.count > limit)
    return try Self.result(result)
  }

  private static func result<T: Encodable>(_ value: T, code: String? = nil) throws -> CLICommandResult {
    let data = try JSONEncoder().encode(value)
    return CLICommandResult(exitCode: code == nil ? .success : .failure,
                            stdout: (String(data: data, encoding: .utf8) ?? "{}") + "\n",
                            stderr: code.map { $0 + "\n" } ?? "")
  }

  private static func failure(_ code: String, exitCode: CLIExitCode, stderr: String? = nil) -> CLICommandResult {
    let data = try? JSONEncoder().encode(AppCommandFailure(error: code, exitCode: exitCode.rawValue))
    return CLICommandResult(exitCode: exitCode, stdout: data.flatMap { String(data: $0, encoding: .utf8) }.map { $0 + "\n" } ?? "{}\n",
                            stderr: (stderr ?? code) + "\n")
  }
}

private struct AppCancelResponse: Decodable {
  var identity: String
  var profile: String
  var sessionId: String
  var owner: String
  var outcome: String
}
private struct AppCancelOutput: Encodable {
  var response: AppCancelResponse
  var status: String?
  enum CodingKeys: String, CodingKey { case identity, profile, sessionId, owner, outcome, status }
  func encode(to encoder: Encoder) throws {
    var box = encoder.container(keyedBy: CodingKeys.self)
    try box.encode(response.identity, forKey: .identity)
    try box.encode(response.profile, forKey: .profile)
    try box.encode(response.sessionId, forKey: .sessionId)
    try box.encode(response.owner, forKey: .owner)
    try box.encode(response.outcome, forKey: .outcome)
    try box.encode(status, forKey: .status)
  }
}
private struct AppCancelAmbiguityDetails: Decodable { var sessionIds: [String]; var pendingRunCount: Int }
private struct AppCancelAmbiguity: Encodable {
  var error: String
  var exitCode: Int
  var sessionIds: [String]
  var pendingRunCount: Int
}

private struct AppCommandFailure: Encodable { var error: String; var exitCode: Int32 }
private struct AppInstanceBusyFailure: Decodable {
  struct Detail: Decodable { var runningSessionId: String? }
  var error: Detail
}
private struct AppInstanceBusyOutput: Encodable { var error: String; var sessionId: String; var exitCode: Int32 }

private struct AppReloadResponse: Codable {
  struct Definition: Codable { var outcome: String; var versionId: String?; var digest: String? }
  struct Bindings: Codable { var respawnRequired: Bool; var respawned: Bool }
  var profile: String
  var revision: Int?
  var identity: String
  var workflowId: String
  var workflowDirectory: String
  var sourceChanged: Bool
  var definition: Definition
  var eventBindings: Bindings
  var handoff: String
  var runtimeStatus: String
  var committed: Bool
}

private struct AppReloadFailure: Codable {
  struct Detail: Codable { var code: String }
  var error: Detail?
  var committed: Bool?
  var partial: String?
  var running: Int?
  var queued: Int?

  func sanitized(code: String) -> AppReloadFailure {
    AppReloadFailure(error: Detail(code: code), committed: committed,
      partial: partial.flatMap(EnvironmentClientStatus.safeCode), running: running, queued: queued)
  }
}

private struct AppLaunch: Decodable {
  var id: String
  var status: String
  var sessionId: String?
  var error: String?
  func output(includeError: Bool) -> AppLaunchOutput {
    AppLaunchOutput(launchId: id, sessionId: sessionId, status: status,
                    error: error.flatMap(EnvironmentClientStatus.safeCode), includeError: includeError)
  }
}

private struct AppLaunchOutput: Encodable {
  var launchId: String
  var sessionId: String?
  var status: String
  var error: String?
  var includeError: Bool
  enum CodingKeys: String, CodingKey { case launchId, sessionId, status, error }
  func encode(to encoder: Encoder) throws {
    var box = encoder.container(keyedBy: CodingKeys.self)
    try box.encode(launchId, forKey: .launchId)
    try box.encode(sessionId, forKey: .sessionId)
    try box.encode(status, forKey: .status)
    if includeError { try box.encode(error, forKey: .error) }
  }
}

private struct AppExecutionDetail: Decodable {
  struct Session: Decodable { var status: String }
  var session: Session
}
private struct AppExecution: Codable {
  var sessionId: String
  var status: String
  var startedAt: String?
  var endedAt: String?
  var updatedAt: String?
  var currentStepId: String?
  enum CodingKeys: String, CodingKey { case sessionId, status, startedAt, endedAt, updatedAt, currentStepId }
  func encode(to encoder: Encoder) throws {
    var box = encoder.container(keyedBy: CodingKeys.self)
    try box.encode(sessionId, forKey: .sessionId)
    try box.encode(status, forKey: .status)
    try box.encode(startedAt, forKey: .startedAt)
    try box.encode(endedAt, forKey: .endedAt)
    try box.encode(updatedAt, forKey: .updatedAt)
    try box.encode(currentStepId, forKey: .currentStepId)
  }
}
private struct AppExecutions: Decodable { var items: [AppExecution]; var truncated: Bool }
private struct AppExecutionsOutput: Encodable {
  var identity: String
  var profile: String
  var items: [AppExecution]
  var truncated: Bool
}
