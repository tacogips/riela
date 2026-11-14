import Foundation
import RielaAdapters
import RielaAddons
import RielaCore
import RielaEvents
import RielaGraphQL
import RielaHook
import RielaServer

public struct SessionContinueCommand: Sendable {
  public init() {}

  public func run(_ options: CLICommandOptions) async -> CLICommandResult {
    guard let sessionId = options.target else {
      return CLICommandResult(exitCode: .usage, stderr: "session continue requires a session id")
    }
    do {
      let parsed = try ParsedParityOptions(options.arguments)
      return await SessionResumeCommand().run(SessionResumeOptions(
        sessionId: sessionId,
        output: options.output,
        scope: parsed.scope,
        workflowDefinitionDir: parsed.workflowDefinitionDir,
        workingDirectory: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath,
        mockScenarioPath: parsed.mockScenarioPath,
        sessionStore: parsed.sessionStore
      ))
    } catch let error as CLIUsageError {
      return failure(error.message, output: options.output, options: options)
    } catch {
      return failure("\(error)", output: options.output, options: options)
    }
  }
}

public struct ScopedParityCommandRunner: Sendable {
  var liveEventServer: any EventLiveServing

  public init() {
    self.liveEventServer = DefaultEventLiveServer()
  }

  init(liveEventServer: any EventLiveServing) {
    self.liveEventServer = liveEventServer
  }

  public func run(_ command: ScopedCommand) async -> CLICommandResult {
    do {
      let options = command.options
      let parityArguments: [String]
      if command.kind == .callStep || command.kind == .workflowCall,
        let first = options.arguments.first,
        !first.hasPrefix("--") {
        parityArguments = Array(options.arguments.dropFirst())
      } else if command.kind == .events,
        options.command == "schedules",
        let first = options.arguments.first,
        !first.hasPrefix("--") {
        parityArguments = Array(options.arguments.dropFirst())
      } else {
        parityArguments = options.arguments
      }
      let parsed = try ParsedParityOptions(parityArguments)
      switch command.kind {
      case .callStep, .workflowCall:
        return await callStep(options: options, parsed: parsed)
      case .graphql, .gql:
        let result = try graphqlResult(kind: command.kind, options: options, parsed: parsed)
        return try render(result, options: options) { result in result.records.joined(separator: "\n") + "\n" }
      case .hook:
        let vendor = try hookVendor(options.command ?? "codex")
        let payload = try hookPayload(options: options, parsed: parsed)
        let parsedHook = try HookParsing.parse(payload, vendor: vendor)
        let result = ScopedParityCommandResult(
          scope: command.kind.rawValue,
          command: options.command,
          target: options.target,
          status: "ok",
          records: [
            "vendor=\(parsedHook.context.vendor.rawValue)",
            "event=\(parsedHook.context.eventName)",
            "agentSessionId=\(parsedHook.context.agentSessionId)"
          ]
        )
        let rendered = try render(result, options: options) { result in result.records.joined(separator: "\n") + "\n" }
        return rendered.withHookInferenceWarning(from: parsedHook.context)
      case .events:
        let result = try await eventResult(options: options, parsed: parsed)
        return try render(result, options: options) { result in result.records.joined(separator: "\n") + "\n" }
      case .serve:
        let response = try await serverResponse(options: options, parsed: parsed)
        let result = ScopedParityCommandResult(
          scope: command.kind.rawValue,
          command: options.command,
          target: options.target,
          status: response.status == 200 ? "ok" : "failed",
          records: ["status=\(response.status)", "body=\(response.body)"]
        )
        return try render(result, options: options) { result in result.records.joined(separator: "\n") + "\n" }
      }
    } catch let error as CLIUsageError {
      return failure(error.message, output: command.options.output, options: command.options)
    } catch {
      return failure("\(error)", output: command.options.output, options: command.options)
    }
  }
}

private extension CLICommandResult {
  func withHookInferenceWarning(from context: HookContext) -> CLICommandResult {
    guard !context.inferredFields.isEmpty else {
      return self
    }
    return CLICommandResult(
      exitCode: exitCode,
      stdout: stdout,
      stderr: stderr.appendingHookWarning(
        "warning: hook context inferred fields: \(context.inferredFields.sorted().joined(separator: ","))"
      )
    )
  }
}

private extension String {
  func appendingHookWarning(_ warning: String) -> String {
    isEmpty ? warning : "\(self)\n\(warning)"
  }
}

fileprivate extension ScopedParityCommandRunner {
  private func graphqlResult(kind: ScopedCommandKind, options: CLICommandOptions, parsed: ParsedParityOptions) throws -> ScopedParityCommandResult {
    let action = options.command ?? "schema"
    let records: [String]
    switch action {
    case "schema":
      records = [GraphQLContractProjector.schemaContract]
    case "session", "inspect-session", "workflow-session":
      let snapshot = try loadRuntimeSnapshot(sessionId: options.target, parsed: parsed, action: action)
      let projected = GraphQLContractProjector.project(
        session: snapshot.session,
        communications: snapshot.workflowMessages
      )
      records = [try jsonString(projected)]
    case "manager-session":
      let snapshot = try loadRuntimeSnapshot(sessionId: options.target, parsed: parsed, action: action)
      let view = GraphQLManagerSessionViewDTO(
        session: .object([
          "sessionId": .string(snapshot.session.sessionId),
          "workflowId": .string(snapshot.session.workflowId),
          "status": .string(snapshot.session.status.rawValue)
        ]),
        messages: .array(snapshot.workflowMessages.map { .string($0.communicationId) })
      )
      records = [try jsonString(view)]
    case "send-manager-message":
      var snapshot = try loadRuntimeSnapshot(sessionId: options.target, parsed: parsed, action: action)
      let managerPayload = try managerMessagePayload(parsed: parsed, action: action)
      let sourceExecution = try latestExecution(snapshot: snapshot, action: action)
      let nextOrder = (snapshot.workflowMessages.map(\.createdOrder).max() ?? 0) + 1
      let communicationId = "graphql-manager-\(snapshot.session.sessionId)-\(nextOrder)"
      let message = WorkflowMessageRecord(
        communicationId: communicationId,
        workflowExecutionId: snapshot.session.sessionId,
        fromStepId: nil,
        toStepId: snapshot.session.currentStepId ?? sourceExecution.stepId,
        routingScope: .workflow,
        deliveryKind: .direct,
        sourceStepExecutionId: sourceExecution.executionId,
        payload: managerPayload,
        lifecycleStatus: .delivered,
        createdOrder: nextOrder,
        createdAt: Date(timeIntervalSince1970: Double(nextOrder))
      )
      snapshot.workflowMessages.append(message)
      try runtimePersistenceStore(parsed: parsed).save(snapshot)
      records = [try jsonString(GraphQLSendManagerMessagePayload(
        accepted: true,
        managerMessageId: communicationId,
        parsedIntent: [GraphQLManagerIntentSummaryDTO(kind: "message", targetId: message.toStepId, reason: "persisted manager-control message")],
        createdCommunicationIds: [communicationId],
        queuedNodeIds: message.toStepId.map { [$0] } ?? [],
        workflowId: snapshot.session.workflowId,
        workflowExecutionId: snapshot.session.sessionId,
        managerSessionId: snapshot.session.sessionId
      ))]
    case "replay-communication":
      let communicationId = try requiredGraphQLTarget(options: options, action: action)
      var snapshot = try loadRuntimeSnapshot(containingCommunicationId: communicationId, parsed: parsed, action: action)
      guard let source = snapshot.workflowMessages.first(where: { $0.communicationId == communicationId }) else {
        throw CLIUsageError("graphql \(action) communication not found: \(communicationId)")
      }
      let nextOrder = (snapshot.workflowMessages.map(\.createdOrder).max() ?? 0) + 1
      let replayedId = "\(communicationId)-replay-\(nextOrder)"
      snapshot.workflowMessages.append(WorkflowMessageRecord(
        communicationId: replayedId,
        workflowExecutionId: source.workflowExecutionId,
        fromStepId: source.fromStepId,
        toStepId: source.toStepId,
        routingScope: source.routingScope,
        deliveryKind: source.deliveryKind,
        sourceStepExecutionId: source.sourceStepExecutionId,
        transitionCondition: source.transitionCondition,
        payload: source.payload,
        artifactRefs: source.artifactRefs,
        lifecycleStatus: .delivered,
        createdOrder: nextOrder,
        createdAt: Date(timeIntervalSince1970: Double(nextOrder))
      ))
      try runtimePersistenceStore(parsed: parsed).save(snapshot)
      records = [try jsonString(GraphQLReplayCommunicationPayload(sourceCommunicationId: communicationId, workflowExecutionId: snapshot.session.sessionId, replayedCommunicationId: replayedId, status: "replayed"))]
    case "retry-communication-delivery", "retry-communication":
      let communicationId = try requiredGraphQLTarget(options: options, action: action)
      let snapshot = try loadRuntimeSnapshot(containingCommunicationId: communicationId, parsed: parsed, action: action)
      guard snapshot.workflowMessages.contains(where: { $0.communicationId == communicationId }) else {
        throw CLIUsageError("graphql \(action) communication not found: \(communicationId)")
      }
      records = [try jsonString(GraphQLRetryCommunicationDeliveryPayload(communicationId: communicationId, activeDeliveryAttemptId: "\(communicationId)-retry", status: "queued"))]
    default:
      throw CLIUsageError("unknown graphql command '\(action)'")
    }
    return ScopedParityCommandResult(scope: kind.rawValue, command: options.command, target: options.target, status: "ok", records: records)
  }

  private func managerMessagePayload(parsed: ParsedParityOptions, action: String) throws -> JSONObject {
    if parsed.messageJSON != nil && parsed.messageFile != nil {
      throw CLIUsageError("graphql \(action) accepts only one of --message-json or --message-file")
    }
    let workingDirectory = parsed.workingDirectory ?? FileManager.default.currentDirectoryPath
    if let messageJSON = parsed.messageJSON {
      return try JSONReferenceLoader().object(from: messageJSON, workingDirectory: workingDirectory)
    }
    if let messageFile = parsed.messageFile {
      return try JSONReferenceLoader().object(from: messageFile, workingDirectory: workingDirectory)
    }
    throw CLIUsageError("graphql \(action) requires --message-json or --message-file")
  }

  private func runtimePersistenceStore(parsed: ParsedParityOptions) -> SQLiteWorkflowRuntimePersistenceStore {
    let workingDirectory = parsed.workingDirectory ?? FileManager.default.currentDirectoryPath
    let sessionRoot = CLIWorkflowSessionStore.resolveRootDirectory(
      sessionStore: parsed.sessionStore,
      scope: parsed.scope,
      workingDirectory: workingDirectory
    )
    return SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionRoot))
  }

  private func loadExistingWorkflowMessages(
    sessionId: String,
    persistenceStore: SQLiteWorkflowRuntimePersistenceStore
  ) throws -> [WorkflowMessageRecord] {
    do {
      return try persistenceStore.load(sessionId: sessionId).workflowMessages
    } catch WorkflowRuntimePersistenceStoreError.notFound(_) {
      return []
    }
  }

  private func loadRuntimeSnapshot(sessionId rawSessionId: String?, parsed: ParsedParityOptions, action: String) throws -> WorkflowRuntimePersistenceSnapshot {
    let sessionId = try requiredGraphQLTargetValue(rawSessionId, action: action, label: "persisted session id")
    let store = runtimePersistenceStore(parsed: parsed)
    return try store.load(sessionId: sessionId)
  }

  private func loadRuntimeSnapshot(containingCommunicationId communicationId: String, parsed: ParsedParityOptions, action: String) throws -> WorkflowRuntimePersistenceSnapshot {
    let snapshots = try runtimePersistenceStore(parsed: parsed).loadAll()
    let matches = snapshots.filter { snapshot in
      snapshot.workflowMessages.contains { $0.communicationId == communicationId }
    }
    guard let snapshot = matches.first else {
      throw CLIUsageError("graphql \(action) communication not found: \(communicationId)")
    }
    guard matches.count == 1 else {
      throw CLIUsageError("graphql \(action) communication id is ambiguous across sessions: \(communicationId)")
    }
    return snapshot
  }

  private func requiredGraphQLTarget(options: CLICommandOptions, action: String) throws -> String {
    try requiredGraphQLTargetValue(options.target, action: action, label: "target")
  }

  private func requiredGraphQLTargetValue(_ value: String?, action: String, label: String) throws -> String {
    guard let value, !value.isEmpty else {
      throw CLIUsageError("graphql \(action) requires a \(label)")
    }
    return value
  }

  private func latestExecution(snapshot: WorkflowRuntimePersistenceSnapshot, action: String) throws -> WorkflowStepExecution {
    guard let execution = snapshot.session.executions.last else {
      throw CLIUsageError("graphql \(action) requires a persisted step execution")
    }
    return execution
  }

  private func serverResponse(options: CLICommandOptions, parsed: ParsedParityOptions) async throws -> ServerResponseDescriptor {
    let action = options.command ?? "status"
    let handler = DeterministicServerRouteHandler()
    switch action {
    case "status", "health":
      return await handler.route(ServerRequestEnvelope(method: "GET", path: "/healthz"), context: serverContext(parsed: parsed))
    case "overview":
      return await handler.route(ServerRequestEnvelope(method: "GET", path: "/overview"), context: serverContext(parsed: parsed))
    case "graphql":
      let bodyObject: JSONObject
      if let target = options.target {
        bodyObject = try JSONReferenceLoader().object(from: target, workingDirectory: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath)
      } else {
        bodyObject = ["query": .string(GraphQLContractProjector.schemaContract), "variables": .object([:])]
      }
      let body = try JSONEncoder().encode(JSONValue.object(bodyObject))
      return await handler.route(ServerRequestEnvelope(method: "POST", path: "/graphql", body: body), context: serverContext(parsed: parsed))
    default:
      let route = options.target ?? action
      let response = await DeterministicServerRouteHandler().route(
        ServerRequestEnvelope(method: "GET", path: route.hasPrefix("/") ? route : "/\(route)"),
        context: serverContext(parsed: parsed)
      )
      return response
    }
  }

  private func serverContext(parsed: ParsedParityOptions) -> ServerRequestContext {
    ServerRequestContext(inheritedEnvironment: parsed.sessionStore.map { ["RIELA_MANAGER_SESSION_ID": $0] } ?? [:])
  }

  private func callStep(options: CLICommandOptions, parsed: ParsedParityOptions) async -> CLICommandResult {
    guard let workflowId = options.command,
      let workflowRunId = options.target,
      let stepId = options.arguments.first,
      !stepId.hasPrefix("--")
    else {
      return CLICommandResult(exitCode: .usage, stderr: "call-step requires <workflow-id> <workflow-run-id> <step-id>")
    }
    do {
      if parsed.messageJSON != nil && parsed.messageFile != nil {
        throw CLIUsageError("use only one of --message-json or --message-file")
      }
      let workingDirectory = parsed.workingDirectory ?? FileManager.default.currentDirectoryPath
      let persisted = try CLIWorkflowSessionResolution.loadPersistedSession(
        sessionId: workflowRunId,
        sessionStore: parsed.sessionStore,
        scope: parsed.scope,
        workingDirectory: workingDirectory
      )
      guard persisted.record.session.workflowId == workflowId else {
        throw CLIUsageError("workflow id mismatch: session '\(workflowRunId)' belongs to '\(persisted.record.session.workflowId)', not '\(workflowId)'")
      }
      guard parsed.continueSession || (persisted.record.session.status != .completed && persisted.record.session.status != .failed) else {
        throw CLIUsageError("cannot call step '\(stepId)' on terminal session '\(workflowRunId)' with status '\(persisted.record.session.status.rawValue)'")
      }
      let resolution = WorkflowResolutionOptions(
        workflowName: persisted.record.workflowName,
        scope: persisted.record.resolution.scope,
        workflowDefinitionDir: parsed.workflowDefinitionDir ?? persisted.record.resolution.workflowDefinitionDir,
        workingDirectory: workingDirectory
      )
      let bundle = try FileSystemWorkflowBundleResolver().resolve(resolution)
      guard bundle.workflow.workflowId == workflowId else {
        throw CLIUsageError("workflow '\(persisted.record.workflowName)' resolved to workflowId '\(bundle.workflow.workflowId)', not '\(workflowId)'")
      }
      guard bundle.workflow.steps.contains(where: { $0.id == stepId }) else {
        throw CLIUsageError("call-step target step not found: \(stepId)")
      }
      var workflow = bundle.workflow
      if let promptVariant = parsed.promptVariant,
        let stepIndex = workflow.steps.firstIndex(where: { $0.id == stepId }) {
        workflow.steps[stepIndex].promptVariant = promptVariant
      }
      let persistedResolution = CLIWorkflowSessionResolution.resolutionForPersistence(
        resolution: resolution,
        resolvedSourceScope: bundle.sourceScope
      )
      var variables = try parsed.variables.map { try JSONReferenceLoader().object(from: $0, workingDirectory: resolution.workingDirectory) } ?? [:]
      if let resumeStepExecutionId = parsed.resumeStepExecutionId {
        variables["resumeStepExecId"] = .string(resumeStepExecutionId)
        variables["resumedFromNodeExecId"] = .string(resumeStepExecutionId)
      }
      let adapter: any NodeAdapter
      if let scenarioPath = parsed.mockScenarioPath {
        adapter = try ScenarioNodeAdapter(
          scenario: WorkflowMockScenarioLoader().loadScenario(at: absoluteURL(
            scenarioPath,
            relativeTo: URL(fileURLWithPath: resolution.workingDirectory)
          ).path),
          fallback: DeterministicLocalNodeAdapter()
        )
      } else {
        adapter = DeterministicLocalNodeAdapter()
      }
      let storeRoot = CLIWorkflowSessionStore.resolveRootDirectory(
        sessionStore: parsed.sessionStore,
        scope: persistedResolution.scope,
        workingDirectory: resolution.workingDirectory
      )
      let persistenceStore = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: storeRoot))
      let existingMessages = try loadExistingWorkflowMessages(sessionId: persisted.record.session.sessionId, persistenceStore: persistenceStore)
      let runtimeStore = InMemoryWorkflowRuntimeStore()
      var seededSession = persisted.record.session
      seededSession.status = .running
      seededSession.currentStepId = stepId
      await runtimeStore.seedSession(seededSession)
      await runtimeStore.seedWorkflowMessages(existingMessages)
      if let directMessage = try directCallMessageObject(parsed: parsed, workingDirectory: resolution.workingDirectory) {
        let sourceExecutionId = seededSession.executions.last?.executionId ?? "\(stepId)-direct-call-input"
        _ = try await runtimeStore.appendWorkflowMessage(WorkflowMessageAppendInput(
          workflowExecutionId: seededSession.sessionId,
          fromStepId: nil,
          toStepId: stepId,
          sourceStepExecutionId: sourceExecutionId,
          payload: directMessage,
          artifactRefs: []
        ))
      }
      if parsed.promptVariant != nil || parsed.resumeStepExecutionId != nil {
        let sourceExecutionId = seededSession.executions.last?.executionId ?? "\(stepId)-direct-call-overrides"
        _ = try await runtimeStore.appendWorkflowMessage(WorkflowMessageAppendInput(
          workflowExecutionId: seededSession.sessionId,
          fromStepId: nil,
          toStepId: stepId,
          sourceStepExecutionId: sourceExecutionId,
          payload: [
            "directCallPromptVariant": parsed.promptVariant.map(JSONValue.string) ?? .null,
            "directCallResumeStepExecutionId": parsed.resumeStepExecutionId.map(JSONValue.string) ?? .null
          ],
          artifactRefs: []
        ))
      }
      let runner = DeterministicWorkflowRunner(
        store: runtimeStore,
        adapter: adapter,
        stdioNodeExecutor: LocalWorkflowStdioNodeExecutor()
      )
      let result = try await runner.run(
        DeterministicWorkflowRunRequest(
          workflow: workflow,
          nodePayloads: bundle.nodePayloads,
          variables: variables,
          maxSteps: 1,
          timeoutMs: parsed.timeoutMs,
          resumeSessionId: seededSession.sessionId
        )
      )
      let workflowMessages = try await runtimeStore.listMessages(for: result.session.sessionId, toStepId: nil)
      try CLIWorkflowSessionStore(rootDirectory: storeRoot).save(
        PersistedCLIWorkflowSession(
          workflowName: persisted.record.workflowName,
          session: result.session,
          resolution: persistedResolution,
          mockScenarioPath: parsed.mockScenarioPath
        ),
        runtimeSnapshot: WorkflowRuntimePersistenceProjector.snapshot(session: result.session, workflowMessages: workflowMessages)
      )
      let rendered = try jsonString(result)
      if options.output.isStructured {
        return CLICommandResult(exitCode: CLIExitCode(rawValue: result.exitCode) ?? .failure, stdout: rendered)
      }
      return CLICommandResult(exitCode: CLIExitCode(rawValue: result.exitCode) ?? .failure, stdout: "called step \(stepId)\nstatus: \(result.status.rawValue)\n")
    } catch let error as CLIUsageError {
      return failure(error.message, output: options.output, options: options)
    } catch {
      return failure("\(error)", output: options.output, options: options)
    }
  }

  private func directCallMessageObject(parsed: ParsedParityOptions, workingDirectory: String) throws -> JSONObject? {
    if let messageJSON = parsed.messageJSON {
      let data = Data(messageJSON.utf8)
      let value = try JSONDecoder().decode(JSONValue.self, from: data)
      guard case let .object(object) = value else {
        throw CLIUsageError("--message-json must decode to a JSON object for Swift deterministic input assembly")
      }
      return object
    }
    if let messageFile = parsed.messageFile {
      return try JSONReferenceLoader().object(from: messageFile, workingDirectory: workingDirectory)
    }
    return nil
  }

  private func hookVendor(_ raw: String) throws -> HookVendor {
    guard let vendor = HookVendor(rawValue: raw) else {
      throw CLIUsageError("invalid hook vendor '\(raw)'")
    }
    return vendor
  }

  private func hookPayload(options: CLICommandOptions, parsed: ParsedParityOptions) throws -> JSONObject {
    if let target = options.target {
      return try JSONReferenceLoader().object(from: target, workingDirectory: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath)
    }
    return [
      "session_id": .string("dry-run-session"),
      "hook_event_name": .string("SessionStart"),
      "cwd": .string(parsed.workingDirectory ?? FileManager.default.currentDirectoryPath)
    ]
  }
}

fileprivate extension ScopedParityCommandRunner {
  private enum EventRootLayout {
    static let configFileName = "events.json"
    static let sourcesDirectoryName = "sources"
    static let bindingsDirectoryName = "bindings"
    static let serveRecordFileName = "serve-record.json"
  }

  private enum EventServeMode {
    static let deterministicLocal = "deterministic-local"
  }

  private enum EventServeStatus {
    static let ready = "ready"
    static let unavailable = "unavailable"
  }

  private struct EventConfig: Codable {
    var sources: [EventSourceContract]
    var bindings: [EventBindingContract]
  }

  private struct PersistedEventReceipt: Codable, Equatable, Sendable {
    var receiptId: String
    var sourceId: String
    var eventId: String
    var status: String
    var duplicate: Bool
    var workflowExecutionId: String?
    var workflowName: String?
    var replayedFromReceiptId: String?
    var reason: String?
    var updatedAt: Date
    var envelope: ExternalEventEnvelope
  }

  private struct PersistedEventReply: Codable, Equatable, Sendable {
    var idempotencyKey: String
    var sourceId: String
    var status: String
    var workflowExecutionId: String?
  }

  private struct PersistedEventSchedule: Codable, Equatable, Sendable {
    var scheduleId: String
    var sourceId: String
    var status: String
    var workflowName: String
    var kind: String
    var timezone: String?
    var nextDueAt: String?
    var cancelledReason: String?
  }

  private func eventResult(options: CLICommandOptions, parsed: ParsedParityOptions) async throws -> ScopedParityCommandResult {
    let action = options.command ?? "validate"
    if let target = options.target,
      parsed.eventRoot == nil,
      FileManager.default.fileExists(atPath: absoluteURL(target, relativeTo: URL(fileURLWithPath: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath)).path),
      action == "validate" || action == "list" || parsed.variables != nil {
      return try await legacyEventResult(options: options, parsed: parsed)
    }
    let root = eventRootURL(parsed: parsed)
    switch action {
    case "validate":
      try FileManager.default.createDirectory(at: receiptsRoot(eventRoot: root), withIntermediateDirectories: true)
      let config = try loadEventConfigIfPresent(eventRoot: root)
      let diagnostics = config.map { EventContractValidator.validate(sources: $0.sources, bindings: $0.bindings) } ?? []
      return ScopedParityCommandResult(
        scope: "events",
        command: action,
        target: options.target,
        status: diagnostics.isEmpty ? "ok" : "failed",
        records: diagnostics.isEmpty ? ["eventRoot=\(root.path)", "receipts=\(receiptsRoot(eventRoot: root).path)"] : diagnostics.map { "\($0.path): \($0.message)" }
      )
    case "emit":
      guard let sourceId = options.target, let eventFile = parsed.eventFile else {
        throw CLIUsageError("events emit requires <source-id> --event-file <path>")
      }
      let config = try loadEventConfigIfPresent(eventRoot: root)
      let source = config?.sources.first { $0.id == sourceId }
      let envelope = try eventEnvelope(
        from: JSONReferenceLoader().object(from: eventFile, workingDirectory: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath),
        sourceIdOverride: sourceId,
        source: source
      )
      let triggerResult: EventDryRunResult?
      if let config {
        triggerResult = await awaitDryRun(config: config, envelope: envelope)
      } else {
        triggerResult = nil
      }
      let receiptId = safeReceiptId(sourceId: sourceId, eventId: envelope.eventId)
      if let existingReceipt = try existingEventReceipt(receiptId: receiptId, eventRoot: root) {
        return ScopedParityCommandResult(
          scope: "events",
          command: action,
          target: sourceId,
          status: "duplicate",
          records: [
            "receipt=\(existingReceipt.receiptId)",
            "status=\(existingReceipt.status)",
            "duplicate=true",
            "workflowExecutionId=\(existingReceipt.workflowExecutionId ?? "-")"
          ]
        )
      }
      let receipt = PersistedEventReceipt(
        receiptId: receiptId,
        sourceId: sourceId,
        eventId: envelope.eventId,
        status: triggerResult?.receipt?.status ?? (parsed.dryRun ? "dry-run" : "received"),
        duplicate: false,
        workflowExecutionId: nil,
        workflowName: triggerResult?.triggers.first?.workflowName,
        replayedFromReceiptId: nil,
        reason: nil,
        updatedAt: Date(timeIntervalSince1970: 0),
        envelope: envelope
      )
      try saveEventReceipt(receipt, eventRoot: root)
      return ScopedParityCommandResult(
        scope: "events",
        command: action,
        target: sourceId,
        status: receipt.status == "failed" ? "failed" : "ok",
        records: ["receipt=\(receipt.receiptId)", "status=\(receipt.status)", "duplicate=false", "workflowExecutionId=\(receipt.workflowExecutionId ?? "-")"]
      )
    case "list":
      let receipts = try listEventReceipts(eventRoot: root)
        .filter { receipt in
          if let target = options.target, receipt.sourceId != target {
            return false
          }
          if let status = parsed.status, receipt.status != status {
            return false
          }
          return true
        }
        .prefix(parsed.limit ?? Int.max)
      let records = receipts.map { "receipt=\($0.receiptId) source=\($0.sourceId) status=\($0.status) workflowExecutionId=\($0.workflowExecutionId ?? "-")" }
      return ScopedParityCommandResult(scope: "events", command: action, target: options.target, status: "ok", records: Array(records))
    case "replay":
      guard let receiptId = options.target else {
        throw CLIUsageError("events replay requires <receipt-id>")
      }
      let original = try loadEventReceipt(receiptId: receiptId, eventRoot: root)
      var replayEnvelope = original.envelope
      replayEnvelope.eventId = "\(original.eventId)-replay"
      let replay = PersistedEventReceipt(
        receiptId: safeReceiptId(sourceId: original.sourceId, eventId: replayEnvelope.eventId),
        sourceId: original.sourceId,
        eventId: replayEnvelope.eventId,
        status: parsed.dryRun ? "dry-run" : "replayed",
        duplicate: false,
        workflowExecutionId: original.workflowExecutionId,
        workflowName: original.workflowName,
        replayedFromReceiptId: original.receiptId,
        reason: parsed.reason,
        updatedAt: Date(timeIntervalSince1970: 0),
        envelope: replayEnvelope
      )
      try saveEventReceipt(replay, eventRoot: root)
      return ScopedParityCommandResult(scope: "events", command: action, target: receiptId, status: "ok", records: ["replayedFrom=\(original.receiptId)", "receipt=\(replay.receiptId)", "status=\(replay.status)"])
    case "serve":
      return try await eventServeResult(root: root, action: action, target: options.target, parsed: parsed)
    case "replies":
      let replies = try listEventReplies(eventRoot: root)
        .filter { reply in
          if let target = options.target, reply.workflowExecutionId != target {
            return false
          }
          if let status = parsed.status, reply.status != status {
            return false
          }
          return true
        }
        .prefix(parsed.limit ?? Int.max)
      return ScopedParityCommandResult(
        scope: "events",
        command: action,
        target: options.target,
        status: "ok",
        records: replies.map { "reply=\($0.idempotencyKey) source=\($0.sourceId) status=\($0.status) workflowExecutionId=\($0.workflowExecutionId ?? "-")" }
      )
    case "schedules":
      let schedulesCommand = options.target ?? "list"
      let scheduleId = options.arguments.first(where: { !$0.hasPrefix("--") })
      switch schedulesCommand {
      case "list":
        let schedules = try listEventSchedules(eventRoot: root)
          .filter { schedule in
            if let status = parsed.status, schedule.status != status {
              return false
            }
            return true
          }
          .prefix(parsed.limit ?? Int.max)
        return ScopedParityCommandResult(
          scope: "events",
          command: action,
          target: schedulesCommand,
          status: "ok",
          records: schedules.map {
            "schedule=\($0.scheduleId) source=\($0.sourceId) status=\($0.status) workflow=\($0.workflowName)"
          }
        )
      case "inspect":
        guard let scheduleId else {
          throw CLIUsageError("events schedules inspect requires <schedule-id>")
        }
        let schedule = try loadEventSchedule(scheduleId: scheduleId, eventRoot: root)
        return ScopedParityCommandResult(
          scope: "events",
          command: action,
          target: schedulesCommand,
          status: "ok",
          records: ["schedule=\(schedule.scheduleId)", "status=\(schedule.status)", "workflow=\(schedule.workflowName)"]
        )
      case "cancel":
        guard let scheduleId else {
          throw CLIUsageError("events schedules cancel requires <schedule-id>")
        }
        var schedule = try loadEventSchedule(scheduleId: scheduleId, eventRoot: root)
        schedule.status = "cancelled"
        schedule.cancelledReason = parsed.reason
        try saveEventSchedule(schedule, eventRoot: root)
        return ScopedParityCommandResult(
          scope: "events",
          command: action,
          target: schedulesCommand,
          status: "ok",
          records: ["schedule=\(schedule.scheduleId)", "status=\(schedule.status)", "reason=\(parsed.reason ?? "-")"]
        )
      default:
        throw CLIUsageError("unknown events schedules command '\(schedulesCommand)'")
      }
    default:
      throw CLIUsageError("unknown events command '\(action)'")
    }
  }

  private func awaitDryRun(config: EventConfig, envelope: ExternalEventEnvelope) async -> EventDryRunResult {
    await DeterministicEventDryRunTrigger().dryRun(EventDryRunRequest(sources: config.sources, bindings: config.bindings, envelope: envelope))
  }

  private func eventServeResult(root: URL, action: String, target: String?, parsed: ParsedParityOptions) async throws -> ScopedParityCommandResult {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let config = try loadEventConfigIfPresent(eventRoot: root)
    if let config, !config.sources.isEmpty, !parsed.dryRun {
      return try await liveEventServer.serve(eventRoot: root, target: target, parsed: parsed, output: .json)
    }
    let serveRecord = root.appendingPathComponent(EventRootLayout.serveRecordFileName)
    let serveStatus = parsed.dryRun ? "dry-run" : EventServeStatus.ready
    try jsonString([
      "eventRoot": .string(root.path),
      "status": .string(serveStatus),
      "mode": .string(EventServeMode.deterministicLocal)
    ] as JSONObject).write(to: serveRecord, atomically: true, encoding: .utf8)
    return ScopedParityCommandResult(
      scope: "events",
      command: action,
      target: target,
      status: "ok",
      records: ["eventRoot=\(root.path)", "serveRecord=\(serveRecord.path)", "status=\(serveStatus)"]
    )
  }

  private func legacyEventResult(options: CLICommandOptions, parsed: ParsedParityOptions) async throws -> ScopedParityCommandResult {
    let action = options.command ?? "validate"
    guard let target = options.target else {
      throw CLIUsageError("events \(action) legacy compatibility requires an event configuration file")
    }
    let path = absoluteURL(target, relativeTo: URL(fileURLWithPath: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath))
    let config = try JSONDecoder().decode(EventConfig.self, from: Data(contentsOf: path))
    let diagnostics = EventContractValidator.validate(sources: config.sources, bindings: config.bindings)
    if action == "validate" {
      return ScopedParityCommandResult(
        scope: "events",
        command: action,
        target: target,
        status: diagnostics.isEmpty ? "ok" : "failed",
        records: diagnostics.isEmpty ? ["valid"] : diagnostics.map { "\($0.path): \($0.message)" }
      )
    }
    if action == "list" {
      return ScopedParityCommandResult(
        scope: "events",
        command: action,
        target: target,
        status: diagnostics.isEmpty ? "ok" : "failed",
        records: ["sources=\(config.sources.map(\.id).joined(separator: ","))", "bindings=\(config.bindings.map(\.id).joined(separator: ","))"]
      )
    }
    guard diagnostics.isEmpty else {
      return ScopedParityCommandResult(
        scope: "events",
        command: action,
        target: target,
        status: "failed",
        records: diagnostics.map { "\($0.path): \($0.message)" }
      )
    }
    guard action == "emit" || action == "replay" else {
      throw CLIUsageError("unknown events command '\(action)'")
    }
    let envelope = try parsed.variables.map {
      try eventEnvelope(from: JSONReferenceLoader().object(from: $0, workingDirectory: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath))
    } ?? defaultEventEnvelope(config: config, action: action)
    let result = await DeterministicEventDryRunTrigger().dryRun(EventDryRunRequest(sources: config.sources, bindings: config.bindings, envelope: envelope))
    return ScopedParityCommandResult(
      scope: "events",
      command: action,
      target: target,
      status: result.accepted ? "ok" : "ignored",
      records: [
        "receipt=\(result.receipt?.status ?? "none")",
        "triggers=\(result.triggers.map(\.bindingId).joined(separator: ","))"
      ]
    )
  }

  private func eventRootURL(parsed: ParsedParityOptions) -> URL {
    let workingDirectory = URL(fileURLWithPath: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath, isDirectory: true)
    if let eventRoot = parsed.eventRoot {
      return absoluteURL(eventRoot, relativeTo: workingDirectory)
    }
    return workingDirectory.appendingPathComponent(".riela/events", isDirectory: true)
  }

  private func receiptsRoot(eventRoot: URL) -> URL {
    eventRoot.appendingPathComponent("receipts", isDirectory: true)
  }

  private func loadEventConfigIfPresent(eventRoot: URL) throws -> EventConfig? {
    let configURL = eventRoot.appendingPathComponent(EventRootLayout.configFileName)
    if FileManager.default.fileExists(atPath: configURL.path) {
      return try JSONDecoder().decode(EventConfig.self, from: Data(contentsOf: configURL))
    }

    let sources = try decodeEventDirectory(
      eventRoot.appendingPathComponent(EventRootLayout.sourcesDirectoryName, isDirectory: true),
      as: EventSourceContract.self
    )
    let bindings = try decodeEventDirectory(
      eventRoot.appendingPathComponent(EventRootLayout.bindingsDirectoryName, isDirectory: true),
      as: EventBindingContract.self
    )
    guard !sources.isEmpty || !bindings.isEmpty else {
      return nil
    }
    return EventConfig(sources: sources, bindings: bindings)
  }

  private func decodeEventDirectory<T: Decodable>(_ directory: URL, as type: T.Type) throws -> [T] {
    guard FileManager.default.fileExists(atPath: directory.path) else {
      return []
    }
    return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      .map { try JSONDecoder().decode(type, from: Data(contentsOf: $0)) }
  }

  private func saveEventReceipt(_ receipt: PersistedEventReceipt, eventRoot: URL) throws {
    let root = receiptsRoot(eventRoot: eventRoot)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(receipt).write(to: eventRecordURL(id: receipt.receiptId, root: root, kind: "event receipt"), options: .atomic)
  }

  private func loadEventReceipt(receiptId: String, eventRoot: URL) throws -> PersistedEventReceipt {
    let url = try eventRecordURL(id: receiptId, root: receiptsRoot(eventRoot: eventRoot), kind: "event receipt")
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw CLIUsageError("event receipt not found: \(receiptId)")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(PersistedEventReceipt.self, from: Data(contentsOf: url))
  }

  private func existingEventReceipt(receiptId: String, eventRoot: URL) throws -> PersistedEventReceipt? {
    let url = try eventRecordURL(id: receiptId, root: receiptsRoot(eventRoot: eventRoot), kind: "event receipt")
    guard FileManager.default.fileExists(atPath: url.path) else {
      return nil
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(PersistedEventReceipt.self, from: Data(contentsOf: url))
  }

  private func listEventReceipts(eventRoot: URL) throws -> [PersistedEventReceipt] {
    let root = receiptsRoot(eventRoot: eventRoot)
    guard FileManager.default.fileExists(atPath: root.path) else {
      return []
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
      .map { try decoder.decode(PersistedEventReceipt.self, from: Data(contentsOf: $0)) }
      .sorted { $0.receiptId < $1.receiptId }
  }

  private func repliesRoot(eventRoot: URL) -> URL {
    eventRoot.appendingPathComponent("replies", isDirectory: true)
  }

  private func schedulesRoot(eventRoot: URL) -> URL {
    eventRoot.appendingPathComponent("schedules", isDirectory: true)
  }

  private func listEventReplies(eventRoot: URL) throws -> [PersistedEventReply] {
    let root = repliesRoot(eventRoot: eventRoot)
    guard FileManager.default.fileExists(atPath: root.path) else {
      return []
    }
    let decoder = JSONDecoder()
    return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
      .map { try decoder.decode(PersistedEventReply.self, from: Data(contentsOf: $0)) }
      .sorted { $0.idempotencyKey < $1.idempotencyKey }
  }

  private func saveEventSchedule(_ schedule: PersistedEventSchedule, eventRoot: URL) throws {
    let root = schedulesRoot(eventRoot: eventRoot)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(schedule).write(to: eventRecordURL(id: schedule.scheduleId, root: root, kind: "event schedule"), options: .atomic)
  }

  private func loadEventSchedule(scheduleId: String, eventRoot: URL) throws -> PersistedEventSchedule {
    let url = try eventRecordURL(id: scheduleId, root: schedulesRoot(eventRoot: eventRoot), kind: "event schedule")
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw CLIUsageError("event schedule not found: \(scheduleId)")
    }
    return try JSONDecoder().decode(PersistedEventSchedule.self, from: Data(contentsOf: url))
  }

  private func listEventSchedules(eventRoot: URL) throws -> [PersistedEventSchedule] {
    let root = schedulesRoot(eventRoot: eventRoot)
    guard FileManager.default.fileExists(atPath: root.path) else {
      return []
    }
    return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
      .map { try JSONDecoder().decode(PersistedEventSchedule.self, from: Data(contentsOf: $0)) }
      .sorted { $0.scheduleId < $1.scheduleId }
  }

  private func safeReceiptId(sourceId: String, eventId: String) -> String {
    let raw = "\(sourceId)\u{0}\(eventId)"
    let encoded = Data(raw.utf8)
      .base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return "event-\(encoded)"
  }

  private func eventRecordURL(id: String, root: URL, kind: String) throws -> URL {
    guard isSafeEventRecordId(id) else {
      throw CLIUsageError("invalid \(kind) id '\(id)'")
    }
    let standardizedRoot = root.standardizedFileURL
    let url = standardizedRoot.appendingPathComponent("\(id).json").standardizedFileURL
    guard isURL(url, containedIn: standardizedRoot) else {
      throw CLIUsageError("invalid \(kind) id '\(id)'")
    }
    return url
  }

  private func isSafeEventRecordId(_ value: String) -> Bool {
    let scalars = Array(value.unicodeScalars)
    guard (1...128).contains(scalars.count), value != ".", value != "..", !value.contains("..") else {
      return false
    }
    return scalars.allSatisfy { scalar in
      isParityASCIIAlphaNumeric(scalar) || scalar == "." || scalar == "-" || scalar == "_"
    }
  }

  private func defaultEventEnvelope(config: EventConfig, action: String) -> ExternalEventEnvelope {
    let source = config.sources.first
    return ExternalEventEnvelope(
      sourceId: source?.id ?? "source",
      eventId: "\(action)-dry-run",
      provider: source?.provider?.rawValue ?? "riela",
      eventType: action,
      receivedAt: Date(timeIntervalSince1970: 0),
      dedupeKey: action == "replay" ? "replay-dry-run" : nil,
      input: ["mode": .string("event-input")]
    )
  }

}
