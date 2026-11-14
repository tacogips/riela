import Foundation
import RielaCore
@testable import RielaCLI
import XCTest

final class RielaSlackExampleParityTests: XCTestCase {
  private enum RepositoryPackage {
    static let manifestFileName = "Package.swift"
  }

  func testSlackGatewayPayloadFixtureMatchesEventBindingAndPreservesThreadMetadata() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-slack-event-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let eventRoot = tempDir.appendingPathComponent("events", isDirectory: true)
    let sourcesRoot = eventRoot.appendingPathComponent("sources", isDirectory: true)
    let bindingsRoot = eventRoot.appendingPathComponent("bindings", isDirectory: true)
    try FileManager.default.createDirectory(at: sourcesRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bindingsRoot, withIntermediateDirectories: true)
    try """
    {
      "id": "slack-gateway-codex",
      "kind": "slack-gateway",
      "provider": "slack"
    }
    """.write(to: sourcesRoot.appendingPathComponent("slack-gateway-codex.json"), atomically: true, encoding: .utf8)
    try """
    {
      "id": "slack-gateway-codex-to-workflow",
      "sourceId": "slack-gateway-codex",
      "match": {
        "eventType": "chat.message"
      },
      "workflowName": "slack-codex-chat",
      "inputMapping": {"mode": "event-input"}
    }
    """.write(
      to: bindingsRoot.appendingPathComponent("slack-gateway-codex-to-workflow.json"),
      atomically: true,
      encoding: .utf8
    )
    let eventFile = repositoryRoot()
      .appendingPathComponent("examples/event-sources/payloads/slack-gateway-message-with-history.json")
    let result = await RielaCLIApplication().run([
      "events", "emit", "slack-gateway-codex",
      "--event-root", eventRoot.path,
      "--event-file", eventFile.path,
      "--read-only",
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let scoped = try JSONDecoder().decode(ScopedParityCommandResult.self, from: Data(result.stdout.utf8))
    XCTAssertEqual(scoped.status, "ok")
    XCTAssertTrue(scoped.records.contains("status=dry-run"), scoped.records.joined(separator: "\n"))
    let receiptURL = try XCTUnwrap(
      FileManager.default.enumerator(at: eventRoot.appendingPathComponent("receipts"), includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL }
        .first { $0.pathExtension == "json" }
    )
    let receipt = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: receiptURL))
    let receiptObject = try XCTUnwrap(jsonObject(receipt))
    let envelope = try XCTUnwrap(jsonObject(receiptObject["envelope"]))
    let conversation = try XCTUnwrap(jsonObject(envelope["conversation"]))
    XCTAssertEqual(conversation["id"], .string("C0123456789"))
    XCTAssertEqual(conversation["threadId"], .string("1780000000.000000"))
    let input = try XCTUnwrap(jsonObject(envelope["input"]))
    XCTAssertEqual(input["text"], .string("Riela, can you summarize what we decided?"))
    XCTAssertEqual(input["provider"], .string("slack"))
    XCTAssertEqual(jsonArray(input["history"])?.count, 1)
  }

  func testSlackAgentTrioMockScenarioProducesThreePersonaHandoffTrail() async throws {
    let root = repositoryRoot()
    let examplesRoot = root.appendingPathComponent("examples", isDirectory: true)
    let sessionStore = root.appendingPathComponent("tmp/test-slack-agent-trio-sessions-\(UUID().uuidString)", isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: sessionStore)
    }
    let result = await RielaCLIApplication().run([
      "workflow", "run", "slack-agent-trio-chat",
      "--workflow-definition-dir", examplesRoot.path,
      "--mock-scenario", examplesRoot
        .appendingPathComponent("slack-agent-trio-chat", isDirectory: true)
        .appendingPathComponent("mock-scenario.json").path,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .success, "\(result.stderr)\n\(result.stdout)")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let payload = try decoder.decode(WorkflowRunResult.self, from: Data(result.stdout.utf8))
    XCTAssertEqual(payload.status, .completed)
    XCTAssertEqual(payload.rootOutput?["replyAs"], .string("rina"))
    XCTAssertEqual(payload.rootOutput?["handoffTrail"], .array([.string("yui"), .string("mika"), .string("rina")]))
    XCTAssertEqual(payload.rootOutput?["handoff_yui"], .bool(false))
    XCTAssertEqual(payload.rootOutput?["handoff_mika"], .bool(false))
    XCTAssertEqual(payload.rootOutput?["handoff_rina"], .bool(false))
  }

  func testSlackGatewayPersonaFixtureMatchesTrioBinding() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-slack-persona-event-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let eventRoot = tempDir.appendingPathComponent("events", isDirectory: true)
    let sourcesRoot = eventRoot.appendingPathComponent("sources", isDirectory: true)
    let bindingsRoot = eventRoot.appendingPathComponent("bindings", isDirectory: true)
    try FileManager.default.createDirectory(at: sourcesRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bindingsRoot, withIntermediateDirectories: true)
    try """
    {
      "id": "slack-gateway-personas",
      "kind": "slack-gateway",
      "provider": "slack"
    }
    """.write(to: sourcesRoot.appendingPathComponent("slack-gateway-personas.json"), atomically: true, encoding: .utf8)
    try """
    {
      "id": "slack-gateway-personas-to-workflow",
      "sourceId": "slack-gateway-personas",
      "match": {
        "eventType": "chat.message"
      },
      "workflowName": "slack-agent-trio-chat",
      "inputMapping": {
        "mode": "template",
        "template": {
          "request": "{{event.input.payload.text}}",
          "history": "{{event.input.payload.history}}",
          "personaCandidates": ["yui", "mika", "rina"],
          "conversationId": "{{event.conversation.id}}",
          "threadId": "{{event.conversation.threadId}}"
        },
        "mirrorToHumanInput": true
      }
    }
    """.write(
      to: bindingsRoot.appendingPathComponent("slack-gateway-personas-to-workflow.json"),
      atomically: true,
      encoding: .utf8
    )
    let eventFile = repositoryRoot()
      .appendingPathComponent("examples/event-sources/payloads/slack-gateway-persona-message-with-history.json")
    let result = await RielaCLIApplication().run([
      "events", "emit", "slack-gateway-personas",
      "--event-root", eventRoot.path,
      "--event-file", eventFile.path,
      "--read-only",
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let scoped = try JSONDecoder().decode(ScopedParityCommandResult.self, from: Data(result.stdout.utf8))
    XCTAssertEqual(scoped.status, "ok")
    XCTAssertTrue(scoped.records.contains("status=dry-run"), scoped.records.joined(separator: "\n"))
    let receiptURL = try XCTUnwrap(
      FileManager.default.enumerator(at: eventRoot.appendingPathComponent("receipts"), includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL }
        .first { $0.pathExtension == "json" }
    )
    let receipt = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: receiptURL))
    let receiptObject = try XCTUnwrap(jsonObject(receipt))
    let envelope = try XCTUnwrap(jsonObject(receiptObject["envelope"]))
    let input = try XCTUnwrap(jsonObject(envelope["input"]))
    XCTAssertEqual(input["text"], .string("Yui, SlackでもMikaとRinaに順番に意見を聞いて、3人で短く議論して。"))
    XCTAssertEqual(jsonArray(input["history"])?.count, 1)
  }

  func testSlackGatewayPersonaSourceUsesDistinctReplyBotTokens() throws {
    let sourceURL = repositoryRoot()
      .appendingPathComponent("examples/event-sources/.riela-events/sources/slack-gateway-personas.json")
    let source = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: sourceURL))
    let sourceObject = try XCTUnwrap(jsonObject(source))
    let replyBots = try XCTUnwrap(jsonObject(sourceObject["replyBots"]))
    XCTAssertEqual(jsonObject(replyBots["yui"])?.stringValue(forKey: "tokenEnv"), "RIELA_SLACK_YUI_BOT_TOKEN")
    XCTAssertEqual(jsonObject(replyBots["mika"])?.stringValue(forKey: "tokenEnv"), "RIELA_SLACK_MIKA_BOT_TOKEN")
    XCTAssertEqual(jsonObject(replyBots["rina"])?.stringValue(forKey: "tokenEnv"), "RIELA_SLACK_RINA_BOT_TOKEN")
  }

  private func repositoryRoot() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    while url.pathComponents.count > 1 {
      if FileManager.default.fileExists(atPath: url.appendingPathComponent(RepositoryPackage.manifestFileName).path) {
        return url
      }
      url.deleteLastPathComponent()
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
  }
}

private extension JSONObject {
  func stringValue(forKey key: String) -> String? {
    self[key]?.stringValue
  }
}
