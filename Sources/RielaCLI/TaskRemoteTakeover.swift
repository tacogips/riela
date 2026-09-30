import Foundation
import RielaCore
import RielaGraphQL
import RielaWork

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct TaskRemoteAuth: Sendable {
  var token: String?
  var managerSessionId: String?
}

protocol TaskHandoverGraphQLTransporting: Sendable {
  func execute(endpoint: String, query: String, variables: JSONObject, auth: TaskRemoteAuth) async throws -> JSONObject
}

struct URLSessionTaskHandoverGraphQLTransport: TaskHandoverGraphQLTransporting {
  var session: URLSession

  func execute(endpoint: String, query: String, variables: JSONObject, auth: TaskRemoteAuth) async throws -> JSONObject {
    guard let url = URL(string: endpoint), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
      throw CLIUsageError("invalid --endpoint value; expected http or https URL")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let token = auth.token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let sessionId = auth.managerSessionId, !sessionId.isEmpty {
      request.setValue(sessionId, forHTTPHeaderField: "X-Riela-Manager-Session-Id")
    }
    let body = try JSONEncoder().encode(GraphQLRequest(query: query, variables: variables))
    request.httpBody = body
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw WorkStoreError("task handover GraphQL request failed with HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
    }
    let payload = try JSONDecoder().decode(JSONObject.self, from: data)
    if case let .array(errors)? = payload["errors"], let first = errors.first,
       case let .object(values) = first, case let .string(message)? = values["message"] {
      throw WorkStoreError("task handover GraphQL request failed: \(message)")
    }
    guard case let .object(dataObject)? = payload["data"] else {
      throw WorkStoreError("task handover GraphQL response has no data object")
    }
    return dataObject
  }
}

struct InProcessTaskHandoverGraphQLTransport: TaskHandoverGraphQLTransporting {
  var executor: any GraphQLDocumentExecuting

  func execute(endpoint: String, query: String, variables: JSONObject, auth: TaskRemoteAuth) async throws -> JSONObject {
    let response = await executor.execute(GraphQLDocumentRequest(query: query, variables: variables))
    guard response.handled else { throw WorkStoreError("task handover GraphQL document was not handled") }
    if case let .object(data)? = response.body["data"] { return data }
    if case let .array(errors)? = response.body["errors"], let first = errors.first,
       case let .object(value) = first, case let .string(message)? = value["message"] {
      throw WorkStoreError("task handover GraphQL request failed: \(message)")
    }
    throw WorkStoreError("task handover GraphQL response has no data object")
  }
}

struct TaskRemoteTakeoverOptions: Sendable {
  var taskId: String
  var handoverId: String?
  var endpoint: String
  var auth: TaskRemoteAuth
  var traits: [HostTrait]
  var workingDirectory: String
  var cloneInto: String?
  var sessionStore: String?
  var scope: WorkflowScope
  var output: WorkflowOutputFormat
}

struct TaskRemoteTakeover {
  var transport: any TaskHandoverGraphQLTransporting = URLSessionTaskHandoverGraphQLTransport(session: .shared)
  var resolver: any WorkflowBundleResolving = FileSystemWorkflowBundleResolver()
  var runner = WorkflowRunCommand()
  var workspace: any WorkspaceHandoverRuntime = GitBranchWorkspaceRuntime()
  var hostResolver: any HostCapabilityResolving = HostCapabilityResolver()

  func run(_ options: TaskRemoteTakeoverOptions) async -> CLICommandResult {
    var heartbeatTask: Task<Void, Never>?
    do {
      let packet = try await fetchPacket(options)
      guard packet.taskId.rawValue == options.taskId else { throw WorkStoreError("handover packet belongs to a different task") }
      guard packet.digest == (try packet.canonicalDigest()) else {
        throw WorkStoreError("handover packet digest verification failed")
      }
      let repository = packet.deliverables.compactMap { ref -> RepositoryDeliverable? in
        guard case let .repository(value) = ref else { return nil }
        return value
      }.first
      guard repository != nil || options.cloneInto == nil else {
        throw WorkStoreError("--clone-into requires a repository handover deliverable")
      }
      var workDirectory = options.cloneInto ?? options.workingDirectory
      var isolation: IsolationRef?
      if let repository {
        guard case .published = repository.state, Self.isURL(repository.remote) else {
          throw WorkStoreError("remote takeover needs a published branch with a reachable remote")
        }
        if let cloneInto = options.cloneInto {
          try Self.clone(remote: repository.remote, into: cloneInto)
          workDirectory = cloneInto
        }
      }
      let reservation = try await reserve(options, packet: packet)
      let sessionId = reservation.sessionId
      let attemptId = reservation.attemptId
      if let repository {
        isolation = try await workspace.materialize(
          repository, into: workDirectory, worktree: false, attempt: AttemptID(attemptId)
        )
        workDirectory = isolation?.path ?? workDirectory
      }
      let workflowResolution = WorkflowResolutionOptions(
        workflowName: packet.workflow.workflowId,
        scope: packet.workflow.scope.flatMap(WorkflowScope.init(rawValue:)) ?? options.scope,
        workflowDefinitionDir: packet.workflow.workflowDefinitionDir,
        workingDirectory: workDirectory
      )
      let bundle = try resolver.resolve(workflowResolution)
      let sessionStoreRoot = options.sessionStore ??
        URL(fileURLWithPath: workDirectory).appendingPathComponent(".riela/sessions").path
      let runtimeStoreRoot = canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStoreRoot)
      let session = WorkflowSession(
        workflowId: bundle.workflow.workflowId, sessionId: sessionId, status: .created,
        entryStepId: packet.contract.resumeStepId, currentStepId: packet.contract.resumeStepId,
        createdAt: Date(), updatedAt: Date(), rootSessionId: sessionId
      )
      let memory = InMemoryWorkflowRuntimeStore()
      await memory.seedSession(session)
      _ = try await memory.importAcceptedHistory(WorkflowHistoryImportInput(
        sessionId: sessionId, sourceSessionId: packet.fromSessionId,
        bundle: packet.history, handoverId: packet.id.rawValue
      ))
      let messages = try await memory.listMessages(for: sessionId, toStepId: nil)
      try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: runtimeStoreRoot).save(
        WorkflowRuntimePersistenceSnapshot(session: (try await memory.loadSession(id: sessionId))!, workflowMessages: messages)
      )
      let leaseState = TaskRemoteLeaseState()
      let control = TaskRemoteRunControl()
      let heartbeat = Task {
        await heartbeatLoop(options: options, attemptId: attemptId, token: reservation.heartbeatToken,
                            intervalMs: reservation.heartbeatMs, leaseState: leaseState, control: control)
      }
      heartbeatTask = heartbeat
      guard let variables = String(data: try JSONCanonical.encode(JSONValue.object([
        "handover": .object(try Self.jsonObject(packet)),
        "rielaTask": .object(["taskId": .string(options.taskId), "attemptId": .string(attemptId), "fence": .integer(Int64(reservation.fence))])
      ])), encoding: .utf8) else { throw WorkStoreError("could not encode remote takeover variables") }
      let runTask = Task { await runner.run(WorkflowRunOptions(
        target: workflowResolution.workflowName, resolution: workflowResolution, variables: variables,
        output: .json, sessionStore: sessionStoreRoot, workingDirectory: workDirectory,
        resumeSessionId: sessionId
      )) }
      await control.install(runTask)
      if await leaseState.isLost { runTask.cancel() }
      let runResult = await runTask.value
      let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: runtimeStoreRoot).load(sessionId: sessionId)
      if await leaseState.isLost {
        heartbeat.cancel()
        _ = await heartbeat.result
        heartbeatTask = nil
        var failed = snapshot
        failed.session.status = .failed
        failed.session.failureKind = .leaseLost
        failed.session.failureReason = "fenced out by a newer takeover"
        failed.session.failedAt = Date()
        failed.session.updatedAt = Date()
        try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: runtimeStoreRoot).save(failed)
        return CLICommandResult(exitCode: .failure, stderr: "fenced out by a newer takeover")
      }
      var deliverables: [DeliverableRef] = DeliverableCollector(workflow: bundle.workflow, nodePayloads: bundle.nodePayloads).collect(snapshot: snapshot)
      if let isolation, let repository {
        _ = try await heartbeatOnce(options: options, attemptId: attemptId, token: reservation.heartbeatToken)
        guard !(await leaseState.isLost) else { throw WorkStoreError("fenced out by a newer takeover") }
        _ = try await workspace.checkpoint(isolation, message: "riela: remote takeover checkpoint \(options.taskId)",
                                           trailer: "Riela-Checkpoint: \(attemptId)/remote-takeover", paths: nil)
        let published = try await workspace.publish(isolation, remote: repository.remote, allowCreate: true,
                                                    branchAllowlist: "riela/task/*")
        deliverables.append(.repository(RepositoryDeliverable(
          root: isolation.path, remote: published.remote, branch: published.branch,
          baseRevision: repository.baseRevision, headCommit: published.sha, state: .published
        )))
      }
      let snapshotObject = try Self.jsonObject(snapshot)
      let deliverableObjects = try deliverables.map(Self.jsonObject)
      let reportVariables: JSONObject = ["input": .object([
        "attemptId": .string(attemptId), "token": .string(reservation.heartbeatToken),
        "snapshot": .object(snapshotObject), "deliverables": .array(deliverableObjects.map(JSONValue.object))
      ])]
      guard try JSONCanonical.encode(JSONValue.object(reportVariables)).count <= 4 * 1024 * 1024 else {
        throw WorkStoreError("remote takeover report exceeds 4 MiB; refusing to truncate the session snapshot")
      }
      _ = try await heartbeatOnce(options: options, attemptId: attemptId, token: reservation.heartbeatToken)
      guard !(await leaseState.isLost) else { throw WorkStoreError("fenced out by a newer takeover") }
      let reportQuery = "mutation ReportAttempt($input: ReportAttemptInput!) { reportAttempt(input: $input) { taskState decisionKind handoverId errors { code message } } }"
      let report = try await transport.execute(endpoint: options.endpoint, query: reportQuery, variables: reportVariables, auth: options.auth)
      let payload = try Self.payload(GraphQLReportAttemptPayload.self, field: "reportAttempt", in: report)
      try Self.throwIfErrors(payload.errors)
      heartbeat.cancel()
      _ = await heartbeat.result
      heartbeatTask = nil
      let result = TaskRemoteTakeoverCommandResult(taskId: options.taskId, attemptId: attemptId, sessionId: sessionId,
        controllerTaskState: payload.taskState ?? "unknown", handoverId: payload.handoverId)
      return CLICommandResult(exitCode: runResult.exitCode, stdout: try jsonString(result))
    } catch let error as CLIUsageError {
      heartbeatTask?.cancel()
      if let heartbeatTask { _ = await heartbeatTask.result }
      return CLICommandResult(exitCode: .usage, stderr: error.message)
    } catch {
      heartbeatTask?.cancel()
      if let heartbeatTask { _ = await heartbeatTask.result }
      return CLICommandResult(exitCode: .failure, stderr: String(describing: error))
    }
  }

  private func fetchPacket(_ options: TaskRemoteTakeoverOptions) async throws -> HandoverPacket {
    let query = """
    query TaskHandover($taskId: String!, $handoverId: String) {
      taskHandover(taskId: $taskId, handoverId: $handoverId) {
        handover { handoverId taskId digest reasonKind resumeStepId brief packet }
        errors { code message }
      }
    }
    """
    let data = try await transport.execute(endpoint: options.endpoint, query: query, variables: [
      "taskId": .string(options.taskId), "handoverId": options.handoverId.map(JSONValue.string) ?? .null
    ], auth: options.auth)
    let result = try Self.payload(GraphQLTaskHandoverPayload.self, field: "taskHandover", in: data)
    try Self.throwIfErrors(result.errors)
    guard let graphPacket = result.handover else { throw WorkStoreError("task has no sealed handover packet") }
    return try JSONCanonical.decoder().decode(HandoverPacket.self, from: JSONEncoder().encode(JSONValue.object(graphPacket.packet)))
  }

  private func reserve(_ options: TaskRemoteTakeoverOptions, packet: HandoverPacket) async throws -> Reservation {
    let query = "mutation TakeoverTask($input: TakeoverTaskInput!) { takeoverTask(input: $input) { attemptId sessionId fence heartbeatToken heartbeatMs errors { code message } } }"
    let data = try await transport.execute(endpoint: options.endpoint, query: query, variables: ["input": .object([
      "taskId": .string(options.taskId), "handoverId": .string(packet.id.rawValue),
      "hostId": .string(await localHostId(options)),
      "traits": .array(options.traits.map { .string($0.rawValue) })
    ])], auth: options.auth)
    let result = try Self.payload(GraphQLTakeoverTaskPayload.self, field: "takeoverTask", in: data)
    try Self.throwIfErrors(result.errors)
    guard let attempt = result.attemptId, let session = result.sessionId, let fence = result.fence,
          let token = result.heartbeatToken, let heartbeatMs = result.heartbeatMs else {
      throw WorkStoreError("controller returned an incomplete takeover reservation")
    }
    return Reservation(attemptId: attempt, sessionId: session, fence: fence, heartbeatToken: token, heartbeatMs: heartbeatMs)
  }

  private func localHostId(_ options: TaskRemoteTakeoverOptions) async -> String {
    do {
      return try await hostResolver.resolve(
        host: "local", scope: options.scope, workingDirectory: options.workingDirectory,
        readOnly: true, localAddonExecutables: [:]
      ).first?.hostId ?? ProcessInfo.processInfo.hostName
    } catch {
      return ProcessInfo.processInfo.hostName
    }
  }

  private func heartbeatLoop(
    options: TaskRemoteTakeoverOptions,
    attemptId: String,
    token: String,
    intervalMs: Int,
    leaseState: TaskRemoteLeaseState,
    control: TaskRemoteRunControl
  ) async {
    while !Task.isCancelled {
      do {
        _ = try await heartbeatOnce(options: options, attemptId: attemptId, token: token)
        try await Task.sleep(for: .milliseconds(max(intervalMs, 1)))
      } catch {
        await leaseState.markLost()
        await control.cancel()
        return
      }
    }
  }

  private func heartbeatOnce(options: TaskRemoteTakeoverOptions, attemptId: String, token: String) async throws -> Bool {
    let query = "mutation Heartbeat($attemptId: String!, $token: String!) { heartbeatAttempt(attemptId: $attemptId, token: $token) { attemptId fence expiresAt fenced errors { code message } } }"
    let data = try await transport.execute(endpoint: options.endpoint, query: query, variables: [
      "attemptId": .string(attemptId), "token": .string(token)
    ], auth: options.auth)
    let result = try Self.payload(GraphQLLeaseStatePayload.self, field: "heartbeatAttempt", in: data)
    try Self.throwIfErrors(result.errors)
    guard !result.fenced else { throw WorkStoreError("fenced out by a newer takeover") }
    return true
  }

  private struct Reservation {
    var attemptId: String; var sessionId: String; var fence: Int; var heartbeatToken: String; var heartbeatMs: Int
  }
}

struct TaskRemoteTakeoverCommandResult: Codable, Sendable {
  var taskId: String; var attemptId: String; var sessionId: String; var controllerTaskState: String; var handoverId: String?
}

private extension TaskRemoteTakeover {
  static func payload<T: Decodable>(_ type: T.Type, field: String, in data: JSONObject) throws -> T {
    guard let value = data[field] else { throw WorkStoreError("GraphQL response omitted \(field)") }
    return try JSONCanonical.decoder().decode(T.self, from: JSONEncoder().encode(value))
  }
  static func throwIfErrors(_ errors: [TaskHandoverGraphQLError]) throws {
    if let error = errors.first { throw WorkStoreError(error.message) }
  }
  static func jsonObject<T: Encodable>(_ value: T) throws -> JSONObject {
    guard case let .object(object) = try JSONCanonical.decoder().decode(JSONValue.self, from: JSONCanonical.encode(value)) else {
      throw WorkStoreError("could not encode task handover payload")
    }
    return object
  }
  static func isURL(_ value: String) -> Bool {
    guard let components = URLComponents(string: value), let scheme = components.scheme?.lowercased() else { return false }
    return ["https", "http", "ssh", "git", "file"].contains(scheme) && (scheme == "file" || components.host != nil)
  }
  static func clone(remote: String, into directory: String) throws {
    guard !FileManager.default.fileExists(atPath: directory) else { throw WorkStoreError("--clone-into path already exists") }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["clone", remote, directory]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw WorkStoreError("could not clone repository for remote takeover") }
  }
}

private actor TaskRemoteRunControl {
  private var run: Task<CLICommandResult, Never>?
  func install(_ task: Task<CLICommandResult, Never>) { run = task }
  func cancel() { run?.cancel() }
}

private actor TaskRemoteLeaseState {
  private(set) var isLost = false
  func markLost() { isLost = true }
}
