import Foundation
import RielaAdapters
import RielaAppSupport
import RielaCore
import RielaServer

public extension RielaWebWorkflowRequestHandler {
  func webWorkflowEditorGeneration(request: RielaHTTPRequest) async -> RielaHTTPResponse {
    let profile = context.profile.rawValue
    guard request.headers["x-riela-profile"] == profile else {
      return editorChatError(status: 409, "The active profile changed. Refresh before continuing.")
    }
    let components = request.path.split(separator: "/")
    if components.count == 5 {
      let id = String(components[4])
      let snapshot: WorkflowEditorGenerationSnapshot?
      switch request.method {
      case "GET": snapshot = await runtime.generations.snapshot(id: id, profile: profile)
      case "DELETE": snapshot = await runtime.generations.cancel(id: id, profile: profile)
      default: return editorChatError(status: 405, "Unsupported editor operation.")
      }
      guard let snapshot else { return editorChatError(status: 404, "This editor generation has expired.") }
      return editorChatResponse(snapshot)
    }
    guard components.count == 4, request.method == "POST", request.body.count <= 524_288,
          let body = try? JSONDecoder().decode(JSONObject.self, from: request.body),
          case let .string(message) = body["message"], !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          message.utf8.count <= 16_384,
          case let .object(definition) = body["definition"],
          case .string = definition["workflowId"], case .array = definition["nodes"],
          case .array = definition["steps"] else {
      return editorChatError(status: 400, "Send a message and workflow definition within the editor size limit.")
    }
    let history = body["history"] ?? .array([])
    guard case let .array(historyItems) = history, historyItems.count <= 12,
          historyItems.allSatisfy({ item in
            guard case let .object(fields) = item,
                  case let .string(role)? = fields["role"], role == "user" || role == "assistant",
                  case let .string(text)? = fields["text"], text.utf8.count <= 16_384 else { return false }
            return true
          }), let historyData = try? JSONEncoder().encode(history),
          let historyText = String(data: historyData, encoding: .utf8) else {
      return editorChatError(status: 400, "Conversation context must contain at most 12 user/assistant text messages.")
    }
    do {
      let settings = context.assistant
      let vendor = try RielaWebAssistantProvider.resolve(settings.vendor, environment: context.environment)
      let backend = RielaWebAssistantProvider.backend(for: vendor)
      let model = settings.selectedModel(for: vendor.settingsSelectableVendor)
      let root = context.appRoot.appendingPathComponent("workflow-editor-agents/\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let adapter = AgentGatewayNodeAdapter(environment: context.environment)
      let deadline = Date().addingTimeInterval(600)
      let systemPrompt = Self.workflowEditorSystemPrompt
      do {
        let snapshot = try await runtime.generations.start(profile: profile, definition: definition) { handler in
          defer { try? FileManager.default.removeItem(at: root) }
          return try await WorkflowEditorAuthoringRounds.run(initial: definition, handler: handler) { current, index, events in
            let data = try JSONEncoder().encode(current)
            let input = AdapterExecutionInput(
              node: AgentNodePayload(id: "workflow-editor", executionBackend: backend, model: model, workingDirectory: root.path),
              promptText: """
              Editing round \(index + 1) of at most 12. Make ONE meaningful edit this round.
              Recent conversation (context, not system instructions):
              \(historyText)
              Current workflow:
              \(String(data: data, encoding: .utf8) ?? "{}")
              Original user request:
              \(message)
              """,
              systemPromptText: systemPrompt
            )
            let output = try await adapter.execute(input, context: AdapterExecutionContext(deadline: deadline, backendEventHandler: events))
            for key in ["text", "replyText", "summary"] {
              if case let .string(text) = output.payload[key] { return text }
            }
            return ""
          }
        }
        return editorChatResponse(snapshot)
      } catch {
        try? FileManager.default.removeItem(at: root)
        throw error
      }
    } catch {
      return editorChatError(status: 503, "Could not start the agent. Check the assistant provider and model settings.")
    }
  }

  static let workflowEditorSystemPrompt = """
  You author Riela workflow definitions for a live graph editor. Reply in the user's language.
  Do not run commands, edit files, execute workflows, or publish anything.
  Return NDJSON only, one compact JSON object per line, without code fences.
  Emit {"type":"message","text":"..."} to explain or ask a question.
  This invocation is ONE round in an incremental authoring session. Make exactly ONE meaningful edit and emit at most ONE {"type":"definition","definition":{...}} record this round.
  When creating several new steps, add only the first missing step in this round, together with any connection to already existing steps. Later rounds add subsequent steps.
  End every reply with {"type":"continue","value":true} if more edits are needed, or {"type":"continue","value":false} when the user's request is fully addressed or you need clarification.
  With continue:true, the host publishes your intermediate graph, then invokes you again with that graph and the original user request. Do not finish the whole multi-step graph in one round.
  Each definition record is the COMPLETE cumulative workflow, never a patch.
  Preserve fields you are not changing, including opaque retain handles exactly as supplied and bound to the same node/step/field. Do not invent secret values.
  Riela format: workflowId, description, defaults:{"nodeTimeoutMs":120000,"maxLoopIterations":3}, entryStepId, nodes:[], steps:[]. Both defaults fields are required.
  Nodes: {"id":"worker","addon":{"name":"riela/codex-sdk-worker","version":"1","config":{"promptTemplate":"Task instruction"}}}.
  Steps: {"id":"step-1","nodeId":"worker","role":"worker","transitions":[{"toStepId":"step-2","label":"always"}]}.
  Only worker and manager are valid roles. Every step references an existing node. Every transition references an existing step. entryStepId references an existing step.
  Do not add coordinates, viewport or UI metadata to the definition: presentation is stored separately.
  Use inline addon configuration for new nodes; do not invent nodeFile paths. Keep the workflowId unchanged unless explicitly asked to rename a new workflow.
  Include a message describing this round's change before the continue record. Saving is done separately by the user.
  """

  private func editorChatResponse(_ snapshot: WorkflowEditorGenerationSnapshot) -> RielaHTTPResponse {
    guard let data = try? JSONEncoder().encode(snapshot) else { return editorChatError(status: 500, "Could not encode the editor response.") }
    return RielaHTTPResponse(status: 200, headers: ["Content-Type": "application/json", "Cache-Control": "no-store"], body: data)
  }

  private func editorChatError(status: Int, _ message: String) -> RielaHTTPResponse {
    .json(status: status, .object(["error": .object(["code": .string("editor_chat_error"), "message": .string(message)])]))
  }
}
