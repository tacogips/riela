import Foundation
import RielaAdapters
import RielaCore
import RielaWorkflowRegistry

enum BuiltinWorkflowImprovementAddon: String, CaseIterable, Sendable {
  case context = "riela/improve-workflow-context"
  case apply = "riela/improve-workflow-apply"
}

struct BuiltinDefinitionRunContext: Sendable {
  var definitionSource: WorkflowDefinitionSource?
  var sessionStoreRoot: String
  var workingDirectory: String
  var cliProcessRunner: (any LocalProcessRunning)?
}

struct WorkflowImprovementApplyOutcome: Equatable, Sendable {
  enum Status: Equatable, Sendable { case applied, unchanged, rejected }
  var status: Status
  var reason: String?
  var versionId: String?
  var auditId: String?
  var digest: String?

  static func classify(updateStdout: String, historyStdout: String?, expectedActorId: String) -> Self? {
    guard let update = parse(updateStdout), let object = update.objectValue,
          let accepted = object["accepted"]?.boolValue else { return nil }
    if accepted {
      let status: Status = object["outcome"]?.stringValue == "unchanged" ? .unchanged : .applied
      return Self(status: status, reason: nil, versionId: object["versionId"]?.stringValue,
        auditId: object["auditId"]?.stringValue, digest: object["digest"]?.stringValue)
    }
    let code = object["error"]?.objectValue?["code"]?.stringValue
    if code == "definition_conflict", let historyStdout, let history = parse(historyStdout),
       let audits = history.arrayValue,
       let latest = audits.first?.objectValue,
       latest["actor"]?.objectValue?["id"]?.stringValue == expectedActorId {
      return Self(status: .applied, reason: nil, versionId: latest["versionId"]?.stringValue,
        auditId: latest["auditId"]?.stringValue, digest: latest["afterDigest"]?.stringValue)
    }
    return Self(status: .rejected, reason: code ?? "cliRejected", versionId: nil, auditId: nil, digest: nil)
  }

  private static func parse(_ text: String) -> JSONValue? {
    try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
  }
}

extension BuiltinWorkflowAddonResolver {
  func executeWorkflowImprovementAddon(
    _ input: WorkflowAddonExecutionInput,
    operation: BuiltinWorkflowImprovementAddon,
    context: AdapterExecutionContext
  ) async throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(.policyBlocked, "unsupported \(input.addon.name) version '\(input.addon.version ?? "")'")
    }
    guard let runContext = definitionRunContext,
          let source = runContext.definitionSource, source.kind == .store,
          let versionId = source.versionId, let storeRoot = source.storeRoot else {
      return output(input, status: "skipped", reason: "oneTimeRun", whenKey: operation == .context ? "improvable" : "applied", whenValue: false)
    }
    switch operation {
    case .context:
      return try buildContext(input, operation: operation, source: source, versionId: versionId, storeRoot: storeRoot, sessionStoreRoot: runContext.sessionStoreRoot)
    case .apply:
      return try await applyProposal(input, operation: operation, source: source, versionId: versionId, storeRoot: storeRoot,
        workingDirectory: runContext.workingDirectory, runner: runContext.cliProcessRunner ?? containerProcessRunner, deadline: context.deadline)
    }
  }

  private func buildContext(
    _ input: WorkflowAddonExecutionInput, operation: BuiltinWorkflowImprovementAddon,
    source: WorkflowDefinitionSource, versionId: String, storeRoot: String, sessionStoreRoot: String
  ) throws -> AdapterExecutionOutput {
    let config = input.addon.config ?? [:]
    let guideline = config["guideline"]?.stringValue ?? ""
    let extras = config["excludeNodeIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
    let maxSteps = min(100, max(1, config["maxStepExecutions"]?.intValue ?? 20))
    let maxChars = min(20_000, max(100, config["maxFieldChars"]?.intValue ?? 2_000))
    let maxBytes = max(1, config["maxContextBytes"]?.intValue ?? 262_144)
    let service = try WorkflowDefinitionService(storeRoot: storeRoot, fileResolver: FileSystemWorkflowBundleResolver())
    let authored = try service.authoredView(workflowName: source.workflowName, versionId: versionId)
    let pinned = try service.loadPinned(versionId: versionId)
    let excluded = WorkflowImprovementDigest.excludedNodeIds(runtimeWorkflow: pinned.workflow, extra: extras)
    let currentSessionId = input.executionIdentity?.workflowExecutionId
    let sessionStore = CLIWorkflowSessionStore(rootDirectory: sessionStoreRoot)
    let previousSessionId = try sessionStore.list(workflowName: source.workflowName, limit: 100)
      .first {
        $0.session.status.isTerminal && $0.session.definitionSource?.kind == .store
          && $0.session.sessionId != currentSessionId
      }?.session.sessionId
    let previous = try previousSessionId.map { try sessionStore.load(sessionId: $0).session }
    var digest: JSONValue = .null
    var evidence: [WorkflowDefinitionEvidenceRef] = []
    var reason: String?
    if let previous {
      let built = WorkflowImprovementDigest.build(session: previous, excludedNodeIds: excluded,
        maxStepExecutions: maxSteps, maxFieldChars: maxChars)
      digest = built.digest
      evidence = built.evidence
    } else {
      reason = "noPreviousRun"
    }
    let payload: JSONObject = [
      "status": .string("ok"), "reason": reason.map(JSONValue.string) ?? .null,
      "workflowName": .string(source.workflowName), "baseVersionId": .string(versionId),
      "baseDigest": .string(source.digest), "definition": authored.view,
      "excludedNodeIds": .array(excluded.sorted().map(JSONValue.string)),
      "runDigest": digest, "evidence": .array(evidence.map(evidenceJSON)),
      "guideline": .string(guideline)
    ]
    guard let data = try? JSONCanonical.encode(payload), data.count <= maxBytes else {
      throw AdapterExecutionError(.invalidOutput, "context_too_large")
    }
    let result = output(input, status: "ok", reason: reason,
      whenKey: "improvable", whenValue: reason == nil, fields: payload)
    return result
  }

  private func applyProposal(
    _ input: WorkflowAddonExecutionInput, operation: BuiltinWorkflowImprovementAddon,
    source: WorkflowDefinitionSource, versionId: String, storeRoot: String, workingDirectory: String,
    runner: any LocalProcessRunning, deadline: Date?
  ) async throws -> AdapterExecutionOutput {
    let config = input.addon.config ?? [:]
    guard let contextStepId = config["contextStepId"]?.stringValue,
          let proposerStepId = config["proposerStepId"]?.stringValue else {
      throw AdapterExecutionError(.policyBlocked, "improve-workflow-apply requires contextStepId and proposerStepId")
    }
    let upstream = input.resolvedInputPayload["upstream"]?.arrayValue ?? []
    guard let contextEntry = upstream.reversed().first(where: { $0.objectValue?["stepId"]?.stringValue == contextStepId }),
          let proposerEntry = upstream.reversed().first(where: { $0.objectValue?["stepId"]?.stringValue == proposerStepId }),
          let contextPayload = contextEntry.objectValue?["output"]?.objectValue?["payload"]?.objectValue,
          let proposal = proposerEntry.objectValue?["output"]?.objectValue?["payload"]?.objectValue else {
      throw AdapterExecutionError(.invalidInput, "improve-workflow-apply is missing upstream context or proposal")
    }
    let service = try configuredWorkflowDefinitionService(storeRoot: storeRoot, projectDirectory: workingDirectory, forWrite: true)
    let pinned = try service.loadPinned(versionId: versionId)
    guard let contextNodeId = contextEntry.objectValue?["nodeId"]?.stringValue,
          pinned.workflow.nodeRegistry.first(where: { $0.id == contextNodeId })?.addon?.name == BuiltinWorkflowImprovementAddon.context.rawValue else {
      throw AdapterExecutionError(.invalidInput, "upstream context step is not the pinned improvement context addon")
    }
    guard contextPayload["status"]?.stringValue == "ok" else {
      return output(input, status: "skipped", reason: contextPayload["reason"]?.stringValue ?? "contextUnavailable", whenKey: "applied", whenValue: false)
    }
    let reason = proposal["reason"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !reason.isEmpty else { return output(input, status: "rejected", reason: "reasonRequired", whenKey: "applied", whenValue: false) }
    guard case let .array(patch)? = proposal["patch"] else { return output(input, status: "rejected", reason: "invalidPatch", whenKey: "applied", whenValue: false) }
    if patch.isEmpty { return output(input, status: "noChange", whenKey: "applied", whenValue: false) }
    let evidence = contextPayload["evidence"]?.arrayValue ?? []
    guard !evidence.isEmpty else { return output(input, status: "rejected", reason: "noEvidence", whenKey: "applied", whenValue: false) }
    guard let definition = contextPayload["definition"], let patched = try? WorkflowDefinitionJSONPatch.apply(.array(patch), to: definition) else {
      return output(input, status: "rejected", reason: "invalidPatch", whenKey: "applied", whenValue: false)
    }
    let excluded = Set(contextPayload["excludedNodeIds"]?.arrayValue?.compactMap(\.stringValue) ?? [])
      .union(config["excludeNodeIds"]?.arrayValue?.compactMap(\.stringValue) ?? [])
      .union(WorkflowImprovementDigest.excludedNodeIds(runtimeWorkflow: pinned.workflow, extra: []))
    guard WorkflowImprovementDigest.touchedExcludedNodes(before: definition, after: patched, excludedNodeIds: excluded).isEmpty else {
      return output(input, status: "rejected", reason: "targetsImprovementNode", whenKey: "applied", whenValue: false)
    }
    guard let operationId = try? input.executionIdentity?.validatedOperationExecutionId(),
          let workflowExecutionId = input.executionIdentity?.workflowExecutionId else {
      throw AdapterExecutionError(.policyBlocked, "missing runtime improvement operation identity")
    }
    let actor = "\(source.workflowName)/\(input.nodeId)@\(workflowExecutionId)/\(operationId)"
    let workingDirectory = definitionRunContext?.workingDirectory ?? FileManager.default.currentDirectoryPath
    let patchURL = FileManager.default.temporaryDirectory.appendingPathComponent("riela-improve-\(UUID().uuidString).json")
    let patchData = try JSONCanonical.encode(JSONValue.array(patch))
    try patchData.write(to: patchURL, options: .atomic)
    defer { try? FileManager.default.removeItem(at: patchURL) }
    let evidenceArgs = evidence.compactMap { value -> [String]? in
      guard let row = value.objectValue, let kind = row["kind"]?.stringValue, let id = row["id"]?.stringValue else { return nil }
      return ["--evidence", "\(kind):\(id)"]
    }.flatMap { $0 }
    let args = ["workflow", "definition", "update", source.workflowName, "--patch", patchURL.path,
      "--reason=\(reason)", "--expected-version", versionId] + evidenceArgs + ["--actor", actor,
      "--actor-kind", "improvementNode", "--session-store", storeRoot, "--working-dir", workingDirectory, "--output", "json"]
    let executable = try executableConfiguration(args: args, config: config)
    let result: LocalProcessResult
    do {
      result = try await runner.run(configuration: executable, stdin: "", deadline: deadline)
    } catch {
      throw AdapterExecutionError(.providerError, "improvement CLI failed to launch")
    }
    var historyStdout: String?
    if WorkflowImprovementApplyOutcome.classify(updateStdout: result.stdout, historyStdout: nil, expectedActorId: actor)?.reason == "definition_conflict" {
      let historyArgs = ["workflow", "definition", "history", source.workflowName, "--limit", "1", "--session-store", storeRoot, "--output", "json"]
      let historyConfig = try executableConfiguration(args: historyArgs, config: config)
      historyStdout = try await runner.run(configuration: historyConfig, stdin: "", deadline: deadline).stdout
    }
    guard let outcome = WorkflowImprovementApplyOutcome.classify(updateStdout: result.stdout, historyStdout: historyStdout, expectedActorId: actor) else {
      throw AdapterExecutionError(.providerError, "improvement CLI returned invalid JSON")
    }
    let status = switch outcome.status {
    case .applied: "applied"
    case .unchanged: "unchanged"
    case .rejected: "rejected"
    }
    var fields: JSONObject = [:]
    for (key, value) in [("versionId", outcome.versionId), ("auditId", outcome.auditId), ("digest", outcome.digest)] {
      if let value { fields[key] = .string(value) }
    }
    fields["cliExitCode"] = .integer(Int64(result.terminationStatus))
    return output(input, status: status, reason: outcome.reason, whenKey: "applied", whenValue: outcome.status == .applied, fields: fields)
  }

  private func executableConfiguration(args: [String], config: JSONObject) throws -> LocalProcessConfiguration {
    let executable: URL
    var arguments = args
    if let configured = config["rielaExecutable"]?.stringValue {
      guard configured.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: configured) else {
        throw AdapterExecutionError(.policyBlocked, "rielaExecutable must be an absolute executable path")
      }
      executable = URL(fileURLWithPath: configured)
    } else if let path = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("riela"),
              FileManager.default.isExecutableFile(atPath: path.path) {
      executable = path
    } else {
      executable = URL(fileURLWithPath: "/usr/bin/env")
      arguments.insert("riela", at: 0)
    }
    return LocalProcessConfiguration(executableURL: executable, arguments: arguments, workingDirectoryURL: workingDirectory)
  }

  private func output(
    _ input: WorkflowAddonExecutionInput, status: String, reason: String? = nil,
    whenKey: String, whenValue: Bool, fields: JSONObject = [:]
  ) -> AdapterExecutionOutput {
    var payload: JSONObject = ["status": .string(status)]
    if let reason { payload["reason"] = .string(reason) }
    for (key, value) in fields { payload[key] = value }
    return AdapterExecutionOutput(provider: "riela-builtin-addon", model: input.addon.name,
      promptText: "", completionPassed: true, when: [whenKey: whenValue], payload: payload)
  }
}

private func configuredWorkflowDefinitionService(storeRoot: String, projectDirectory: String, forWrite: Bool) throws -> WorkflowDefinitionService {
  guard forWrite else {
    return WorkflowDefinitionService(storeRoot: storeRoot, fileResolver: FileSystemWorkflowBundleResolver())
  }
  let retention = try WorkflowDefinitionHistoryConfiguration.resolve(
    homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
    projectDirectory: projectDirectory,
    environment: CLIRuntimeEnvironment.mergedProcessEnvironment()
  )
  return WorkflowDefinitionService(storeRoot: storeRoot, fileResolver: FileSystemWorkflowBundleResolver(), defaultHistoryRetention: retention)
}

private func evidenceJSON(_ evidence: WorkflowDefinitionEvidenceRef) -> JSONValue {
  .object(["kind": .string(evidence.kind.rawValue), "id": .string(evidence.id)])
}

private extension JSONValue {
  var objectValue: JSONObject? { if case let .object(value) = self { return value }; return nil }
  var arrayValue: [JSONValue]? { if case let .array(value) = self { return value }; return nil }
  var boolValue: Bool? { if case let .bool(value) = self { return value }; return nil }
  var intValue: Int? { if case let .integer(value) = self { return Int(exactly: value) }; return nil }
}
