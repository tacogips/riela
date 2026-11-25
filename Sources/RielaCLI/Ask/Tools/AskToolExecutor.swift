import Foundation
import RielaCore
import RielaWorkflowRegistry

struct AskToolExecutor: Sendable {
  let store: BotStore
  let surface: any AskReadSurface
  let proposals: AskActionProposer
  let recorder: any WorkflowActivityRecording
  let environment: [String: String]
  let limits: AskLimits
  let now: @Sendable () -> Date
  var additionalRedactionValues: [String: String] = [:]

  func execute(
    conversationId: String, turnId: String, toolCallId: String, name: String, arguments: JSONObject
  ) async -> AskToolResult {
    let validated: JSONObject
    do {
      try Task.checkCancellation()
      let turn = try store.askConversation(id: conversationId)?.turn
      guard turn?.turnId == turnId, turn?.status == .running else {
        return failure("turn_not_running", "Ask turn is no longer running")
      }
      validated = try AskToolSet.validate(name: name, arguments: arguments)
      try store.reserveAskToolCall(conversationId: conversationId, turnId: turnId, limits: limits)
    } catch {
      return failure(for: error)
    }

    let sessionId = AskActivityKey.sessionId(conversationId)
    var call = AdapterActivityToolCall(
      toolCallId: AskRedaction.text(toolCallId, environment: environment, additionalValues: additionalRedactionValues), title: name,
      toolKind: AskToolSet.all.first { $0.name == name }?.kind.rawValue, status: "inProgress"
    )
    await recorder.record(sessionId: sessionId, executionId: turnId, update: .toolCall(call), at: now())

    let result: AskToolResult
    do {
      let outcome = try await CLIRuntimeEnvironment.$captured.withValue(environment) {
        try await CLIRuntimeEnvironment.$overrides.withValue(nil) {
          try await run(name: name, arguments: validated, conversationId: conversationId, turnId: turnId)
        }
      }
      let value = AskRedaction.apply(outcome.data, environment: environment, additionalValues: additionalRedactionValues)
      result = try cap(value, refs: outcome.refs.lazy.filter(isSafeRef))
    } catch {
      result = failure(for: error)
    }
    // Leave an open call for turn settlement to mark interrupted.
    guard !Task.isCancelled else { return result }
    let accounted: AskToolResult
    do {
      let bytes = try Self.encode(result).count
      accounted = try store.addAskToolBytes(conversationId: conversationId, turnId: turnId, bytes: bytes, limits: limits)
        ? result : failure("budget_exceeded", "Tool byte budget exhausted")
    } catch {
      accounted = failure(for: error)
    }

    call.status = accounted.ok ? "completed" : "failed"
    await recorder.record(sessionId: sessionId, executionId: turnId, update: .toolCall(call), at: now())
    return accounted
  }

  func resolveContext(_ context: AskContext) async throws -> (summary: JSONObject, ref: AskRef)? {
    guard context.kind != .none else { return nil }
    let resolved: (data: JSONObject, ref: AskRef)?
    do {
      resolved = try await CLIRuntimeEnvironment.$captured.withValue(environment) {
        try await CLIRuntimeEnvironment.$overrides.withValue(nil) {
          try await surface.contextSummary(context)
        }
      }
    } catch let error as AskError where error.code == "not_found" {
      resolved = nil
    } catch {
      let error = failure(for: error).error
      throw AskError(code: error?.code ?? "tool_failed", message: error?.message ?? "Context resolution failed")
    }
    guard let resolved, isSafeRef(resolved.ref) else {
      throw AskError(code: "ask_context_not_found", message: "Ask context was not found")
    }
    guard case let .object(redacted) = AskRedaction.apply(.object(resolved.data), environment: environment, additionalValues: additionalRedactionValues) else {
      return ([:], resolved.ref)
    }
    if try Self.encode(redacted).count <= limits.contextSummaryBytes {
      return (redacted, resolved.ref)
    }
    var kept: JSONObject = [:]
    for key in redacted.keys.sorted() {
      var candidate = kept
      candidate[key] = redacted[key]
      if try Self.encode(candidate).count <= limits.contextSummaryBytes {
        kept = candidate
      }
    }
    return (kept, resolved.ref)
  }

  private func run(
    name: String, arguments: JSONObject, conversationId: String, turnId: String
  ) async throws -> (data: JSONValue, refs: [AskRef]) {
    switch name {
    case "session_list": return try await surface.sessionList(arguments)
    case "session_status": return try await surface.sessionStatus(arguments)
    case "session_progress": return try await surface.sessionProgress(arguments)
    case "session_health": return try await surface.sessionHealth(arguments)
    case "session_logs": return try await surface.sessionLogs(arguments)
    case "ops_overview": return try await surface.opsOverview(arguments)
    case "bot_list": return try await surface.botList(arguments)
    case "bot_board": return try await surface.botBoard(arguments)
    case "bot_activity": return try await surface.botActivity(arguments)
    case "routine_list": return try await surface.routineList(arguments)
    case "workflow_list": return try await surface.workflowList(arguments)
    case "workflow_inspect": return try await surface.workflowInspect(arguments)
    case "workflow_validate": return try await surface.workflowValidate(arguments)
    case "definition_history": return try await surface.definitionHistory(arguments)
    case "model_catalog": return try await surface.modelCatalog(arguments)
    case "remote_list": return try await surface.remoteList(arguments)
    case "propose_action":
      guard case let .string(kind)? = arguments["kind"], case let .object(target)? = arguments["target"] else {
        throw AskError(code: "tool_arguments_invalid", message: "Invalid proposal arguments")
      }
      let reason: String?
      if case let .string(value)? = arguments["reason"] {
        reason = value
      } else {
        reason = nil
      }
      let action = try await proposals.propose(
        conversationId: conversationId, turnId: turnId, kind: kind, target: target, reason: reason
      )
      return (.object(["actionId": .string(action.actionId)]), [])
    case "propose_workflow":
      guard case let .object(definition)? = arguments["definition"] else {
        throw AskError(code: "tool_arguments_invalid", message: "A complete workflow definition is required")
      }
      let draft = try store.askConversation(id: conversationId)?.turn?.draftDefinition
      let action = try await proposals.proposeWorkflow(
        conversationId: conversationId, turnId: turnId, definition: definition,
        baseWorkflowId: arguments.askString("baseWorkflowId"), draft: draft
      )
      return (.object(["actionId": .string(action.actionId)]), [])
    default:
      throw AskError(code: "tool_unknown", message: "Unknown Ask tool")
    }
  }

  private func cap(_ value: JSONValue, refs: some Sequence<AskRef>) throws -> AskToolResult {
    let empty = AskToolResult(ok: true)
    let envelopeBytes = try Self.encode(empty).count
    let dataKeyBytes = 8 // Comma, quoted key and colon.
    let budget = max(0, limits.toolResultBytes - envelopeBytes)
    let (data, clipped) = try capData(value, limit: max(0, budget - dataKeyBytes))
    var remaining = budget
    if let data {
      remaining -= try Self.encode(data).count + dataKeyBytes
    }
    var kept: [AskRef] = []
    for ref in refs {
      let bytes = try Self.encode(ref).count + (kept.isEmpty ? 0 : 1)
      guard bytes <= remaining else {
        return AskToolResult(ok: true, data: data, refs: kept, truncated: true)
      }
      kept.append(ref)
      remaining -= bytes
    }
    return AskToolResult(ok: true, data: data, refs: kept, truncated: clipped)
  }

  private func capData(_ value: JSONValue, limit: Int) throws -> (JSONValue?, Bool) {
    let encoded = try Self.encode(value)
    guard encoded.count > limit else { return (value, false) }
    // Capping the serialized preview must allow for JSON's extra quoting and escapes.
    guard limit >= 2 else { return (nil, true) }
    guard let text = String(data: encoded, encoding: .utf8) else {
      throw AskError(code: "tool_failed", message: "Tool result could not be encoded as UTF-8 JSON")
    }
    let encoder = JSONEncoder()
    var remaining = limit - 2
    let prefix = try text.prefix { character in
      remaining -= try encoder.encode(String(character)).count - 2
      return remaining >= 0
    }
    return (.string(String(prefix)), true)
  }

  private func isSafeRef(_ ref: AskRef) -> Bool {
    AskRedaction.text(ref.id, environment: environment, additionalValues: additionalRedactionValues) == ref.id
      && ref.sessionId.map { AskRedaction.text($0, environment: environment, additionalValues: additionalRedactionValues) == $0 } != false
  }

  private func failure(for error: Error) -> AskToolResult {
    if let error = error as? AskWorkflowValidationError {
      let issues = error.issues.map { issue in
        JSONValue.object(["path": .string(issue.path), "message": .string(issue.message)])
      }
      let redacted = AskRedaction.apply(.array(issues), environment: environment, additionalValues: additionalRedactionValues)
      let details = try? cap(redacted, refs: [AskRef]())
      return .init(ok: false, data: details?.data, error: .init(code: "workflow_invalid", message: "Workflow definition is invalid"),
        truncated: details?.truncated ?? true)
    }
    if let error = error as? AskError {
      switch error.code {
      case "ask_conversation_not_found":
        return failure("turn_not_running", "Ask turn is no longer running")
      case "not_found", "turn_not_running", "tool_unknown", "tool_arguments_invalid", "budget_exceeded",
        "action_kind_unknown", "action_target_invalid", "action_limit", "workflow_too_large", "workflow_not_mutable", "workflow_invalid",
        "retain_key_invalid":
        return failure(error.code, error.message)
      default:
        break
      }
    }
    return failure("tool_failed", String(describing: error))
  }

  private func failure(_ code: String, _ message: String) -> AskToolResult {
    let text = AskRedaction.text(message, environment: environment, additionalValues: additionalRedactionValues)
    return AskToolResult(ok: false, error: AskToolFailure(code: code, message: AskLimits.prefix(text, utf8Limit: limits.toolResultBytes)))
  }

  private static func encode(_ value: some Encodable) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }
}
