import ACP
import AgentGatewayAppCore
import Foundation
import RielaCore

enum ACPTranscriptFixtures {
  struct Update: Sendable {
    let wire: String
    let activity: [AdapterActivityUpdate]

    init(_ wire: String, _ activity: AdapterActivityUpdate...) {
      self.wire = wire
      self.activity = activity
    }

    func v1() throws -> ACPSessionUpdate {
      let data = Data(wire.utf8)
      if let typed = try? JSONDecoder().decode(ACPSessionUpdate.self, from: data) { return typed }
      return .other(try JSONDecoder().decode(ACPJSONValue.self, from: data))
    }

    func v2() throws -> ACPV2SessionUpdate {
      try JSONDecoder().decode(ACPV2SessionUpdate.self, from: Data(wire.utf8))
    }
  }

  static let v1: [Update] = [
    .init(#"{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"Think"}}"#, .thought(text: "Think")),
    .init(#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hi"}}"#,
      .message(messageId: nil, text: "Hi", replace: false)),
    .init(#"{"sessionUpdate":"agent_message_chunk","content":{"type":"image","data":"YQ==","mimeType":"image/png"}}"#,
      .other(updateKind: "agent_message_chunk")),
    .init(#"{"sessionUpdate":"agent_thought_chunk","content":{"type":"image","data":"YQ==","mimeType":"image/png"}}"#,
      .other(updateKind: "agent_thought_chunk")),
    .init(#"{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"Hidden"}}"#, .other(updateKind: "user_message_chunk")),
    .init(#"{"sessionUpdate":"tool_call_update","toolCallId":"before","status":"in_progress"}"#,
      .toolCall(.init(toolCallId: "before", status: "in_progress"))),
    .init(#"{"sessionUpdate":"tool_call","toolCallId":"before","title":"Read","kind":"read","status":"pending","locations":[{"path":"file","line":3}]}"#,
      .toolCall(.init(toolCallId: "before", title: "Read", toolKind: "read", status: "pending", locations: [.init(path: "file", line: 3)]))),
    .init(#"{"sessionUpdate":"tool_call_update","toolCallId":"before","status":"completed"}"#,
      .toolCall(.init(toolCallId: "before", status: "completed"))),
    .init(#"{"sessionUpdate":"tool_call","toolCallId":"open","title":"Custom","kind":"custom","status":"pending"}"#,
      .toolCall(.init(toolCallId: "open", title: "Custom", toolKind: "custom", status: "pending"))),
    .init(#"{"sessionUpdate":"plan","entries":[{"content":"Read","status":"pending","priority":"high"}]}"#,
      .plan(planId: "default", entries: [.init(content: "Read", status: "pending", priority: "high")])),
    .init(#"{"sessionUpdate":"plan","entries":[{"content":"Write","status":"future","priority":"urgent"}]}"#,
      .plan(planId: "default", entries: [.init(content: "Write", status: "future", priority: "urgent")])),
    .init(#"{"sessionUpdate":"current_mode_update","currentModeId":"plan"}"#, .mode(modeId: "plan")),
    .init(#"{"sessionUpdate":"available_commands_update","availableCommands":[{"name":"status","description":"See status"}]}"#,
      .commands(names: ["status"])),
    .init(
      #"{"sessionUpdate":"usage_update","used":1200,"size":200000,"cost":{"amount":0.25,"currency":"USD"},"_meta":{"agentGateway":{"inputTokens":900,"outputTokens":300}}}"#,
      .usage([
        "contextUsed": .integer(1200), "contextSize": .integer(200_000), "inputTokens": .integer(900),
        "outputTokens": .integer(300), "cost": .object(["amount": .number(0.25), "currency": .string("USD")])
      ])
    ),
    .init(#"{"sessionUpdate":"usage_update","used":1200}"#, .other(updateKind: "usage_update")),
    .init(#"{"sessionUpdate":"foo_update","raw":"ignored"}"#, .other(updateKind: "foo_update"))
  ]

  static let v2: [Update] = [
    .init(#"{"sessionUpdate":"agent_thought_chunk","messageId":"thought","content":{"type":"text","text":"Think"}}"#, .thought(text: "Think")),
    .init(#"{"sessionUpdate":"agent_thought","messageId":"thought","content":[{"type":"text","text":"Think twice"}]}"#,
      .thought(text: "Think twice")),
    .init(#"{"sessionUpdate":"agent_message_chunk","messageId":"answer","content":{"type":"text","text":"Hi"}}"#,
      .message(messageId: "answer", text: "Hi", replace: false)),
    .init(#"{"sessionUpdate":"agent_message","messageId":"answer","content":[{"type":"text","text":"Hello"}]}"#,
      .message(messageId: "answer", text: "Hello", replace: true)),
    .init(#"{"sessionUpdate":"agent_message_chunk","messageId":"answer","content":{"type":"image","data":"YQ==","mimeType":"image/png"}}"#,
      .other(updateKind: "agent_message_chunk")),
    .init(#"{"sessionUpdate":"user_message_chunk","messageId":"user","content":{"type":"text","text":"Hidden"}}"#,
      .other(updateKind: "user_message_chunk")),
    .init(#"{"sessionUpdate":"user_message","messageId":"user","content":[]}"#, .other(updateKind: "user_message")),
    .init(#"{"sessionUpdate":"tool_call_update","toolCallId":"call","title":"Read","kind":"custom","status":"pending"}"#,
      .toolCall(.init(toolCallId: "call", title: "Read", toolKind: "custom", status: "pending"))),
    .init(#"{"sessionUpdate":"tool_call_update","toolCallId":"call","status":"in_progress","locations":[{"path":"file","line":3}]}"#,
      .toolCall(.init(toolCallId: "call", status: "in_progress", locations: [.init(path: "file", line: 3)]))),
    .init(#"{"sessionUpdate":"tool_call_update","toolCallId":"call","status":"completed"}"#,
      .toolCall(.init(toolCallId: "call", status: "completed"))),
    .init(#"{"sessionUpdate":"tool_call_content_chunk","toolCallId":"call","content":{"type":"terminal","terminalId":"term"}}"#,
      .other(updateKind: "tool_call_content_chunk")),
    .init(#"{"sessionUpdate":"terminal_update","terminalId":"term","output":{"data":"YQ=="}}"#, .other(updateKind: "terminal_update")),
    .init(#"{"sessionUpdate":"terminal_output_chunk","terminalId":"term","data":"YQ=="}"#, .other(updateKind: "terminal_output_chunk")),
    .init(#"{"sessionUpdate":"plan_update","plan":{"type":"items","planId":"plan","entries":[{"content":"Read","priority":"urgent","status":"later"}]}}"#,
      .plan(planId: "plan", entries: [.init(content: "Read", status: "later", priority: "urgent")])),
    .init(#"{"sessionUpdate":"plan_update","plan":{"type":"items","planId":"plan","entries":[]}}"#, .plan(planId: "plan", entries: [])),
    .init(#"{"sessionUpdate":"plan_removed","planId":"plan"}"#, .planRemoved(planId: "plan")),
    .init(#"{"sessionUpdate":"available_commands_update","availableCommands":[{"type":"command","name":"status","description":"See status"},{"type":"future","name":"ignored"}]}"#,
      .commands(names: ["status"])),
    .init(configUpdate, .configOptions(options: [
      ["id": .string("mode"), "category": .string("mode"), "currentValue": .string("plan"), "values": .array([.string("plan")])],
      ["id": .string("model"), "category": .string("model"), "currentValue": .string("x"), "values": .array([.string("x")])]
    ]), .mode(modeId: "plan")),
    .init(#"{"sessionUpdate":"session_info_update","title":"Session"}"#, .sessionInfo(title: "Session")),
    .init(#"{"sessionUpdate":"usage_update","used":2,"size":10,"cost":{"amount":0.25,"currency":"USD"}}"#,
      .usage(["contextUsed": .integer(2), "contextSize": .integer(10), "cost": .object(["amount": .number(0.25), "currency": .string("USD")])])),
    .init(#"{"sessionUpdate":"notice","severity":"warning","title":"Attention","description":"More"}"#,
      .notice(severity: "warning", title: "Attention", description: "More")),
    .init(#"{"sessionUpdate":"subagent_update","sessionId":"child","title":"Child","state":{"state":"running"}}"#,
      .subagent(subSessionId: "child", title: "Child", state: "running")),
    .init(#"{"sessionUpdate":"replay_complete"}"#, .other(updateKind: "replay_complete")),
    .init(#"{"sessionUpdate":"foo_update","raw":"ignored"}"#, .other(updateKind: "foo_update"))
  ]

  private static let configUpdate = """
    {"sessionUpdate":"config_option_update","configOptions":[
      {"configId":"mode","name":"Mode","category":"mode","type":"select","currentValue":"plan","options":[{"value":"plan","name":"Plan"}]},
      {"configId":"model","name":"Model","category":"model","type":"select","currentValue":"x","options":[{"value":"x","name":"X"}]}
    ]}
    """

  static func meta(version: Int) -> ACPJSONValue {
    .object([GatewayACPMetaKey.key(protocolVersion: version): .object([
      "model": .string("actual-model"), "usage": .object(["inputTokens": .integer(4), "outputTokens": .integer(2)]),
      "resultText": .string("Authoritative answer")
    ])])
  }

  static let permissionOptions = [
    ACPPermissionOption(optionId: "allow-1", name: "Allow", kind: "allow_once"),
    ACPPermissionOption(optionId: "reject-1", name: "Reject", kind: "reject_once"),
    ACPPermissionOption(optionId: "custom-1", name: "Ask later", kind: "future")
  ]
}
