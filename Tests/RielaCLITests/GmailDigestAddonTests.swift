import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class GmailDigestAddonTests: XCTestCase {
  func testGmailDigestAddonNormalizesValidatesAndPersistsCursorState() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-gmail-digest-addon-\(UUID().uuidString)", isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: root)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let stateFile = root.appendingPathComponent("state.json").path
    let messageRoot = root.appendingPathComponent("messages", isDirectory: true).path
    let attachmentRoot = root.appendingPathComponent("attachments", isDirectory: true).path
    try Data(#"{"lastFetchedMessageId":"m1","seenMessageIds":["m1"]}"#.utf8)
      .write(to: URL(fileURLWithPath: stateFile))

    let resolver = BuiltinWorkflowAddonResolver(environment: [:])
    let readOutput = try await resolver.execute(
      gmailDigestInput(
        operation: "read-state",
        variables: [
          "nowIso": .string("2026-06-23T04:00:00Z"),
          "workflowInput": .object([
            "stateFile": .string(stateFile),
            "messageFileRoot": .string(messageRoot),
            "attachmentDownloadRoot": .string(attachmentRoot),
            "accountId": .string("primary"),
            "gmailSearchQuery": .string("in:inbox newer_than:1d"),
            "maxMessages": .string("5")
          ])
        ]
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(readOutput.payload["lastFetchedMessageId"], .string("m1"))
    XCTAssertEqual(readOutput.payload["knownMessageIds"], .array([.string("m1")]))
    XCTAssertEqual(readOutput.payload["accountId"], .string("primary"))
    XCTAssertEqual(readOutput.payload["maxMessages"], .number(5))

    let gatewayPayload: JSONObject = [
      "mailGateway": .object([
        "data": .object([
          "data": .object([
            "threads": .object([
              "totalCount": .number(2),
              "pageInfo": .object([
                "hasNextPage": .bool(false),
                "endCursor": .null
              ]),
              "edges": .array([
                .object([
                  "cursor": .string("m2"),
                  "node": .object(thread(
                    id: "thread-m2",
                    messages: [
                      message(
                        id: "m2",
                        subject: "Quarterly report",
                        body: "report summary",
                        date: "2026-06-23T03:30:00Z",
                        files: [
                          [
                            "kind": .string("ATTACHMENT"),
                            "filename": .string("report.pdf"),
                            "mimeType": .string("application/pdf"),
                            "sizeBytes": .number(1024),
                            "downloadKey": .string("attachment-key"),
                            "materializationState": .string("CACHED")
                          ]
                        ]
                      )
                    ]
                  ))
                ]),
                .object([
                  "cursor": .string("m1"),
                  "node": .object(thread(
                    id: "thread-m1",
                    messages: [
                      message(id: "m1", subject: "Old invoice", body: "invoice", date: "2026-06-22T03:30:00Z")
                    ]
                  ))
                ])
              ])
            ])
          ])
        ])
      ])
    ]
    let messageFileSetPayload: JSONObject = [
      "mailGateway": .object([
        "data": .object([
          "data": .object([
            "messageFileSet": .object([
              "accountId": .string("primary"),
              "messageId": .string("m2"),
              "hasFiles": .bool(true),
              "files": .array([
                .object([
                  "kind": .string("BODY_TEXT"),
                  "filename": .string("body.txt"),
                  "mimeType": .string("text/plain"),
                  "sizeBytes": .number(14),
                  "downloadKey": .string("body-key"),
                  "materializationState": .string("CACHED")
                ])
              ])
            ])
          ])
        ])
      ])
    ]
    let normalizeOutput = try await resolver.execute(
      gmailDigestInput(
        operation: "normalize-new-mail",
        resolvedInputPayload: upstreamPayloads([readOutput.payload, gatewayPayload, messageFileSetPayload]),
        variables: ["nowIso": .string("2026-06-23T04:00:00Z")]
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(normalizeOutput.when["has_new_mail"], true)
    XCTAssertEqual(normalizeOutput.payload["fetchedMessageCount"], .number(2))
    XCTAssertEqual(normalizeOutput.payload["selectedMessageCount"], .number(1))
    XCTAssertEqual(normalizeOutput.payload["lastFetchedMessageId"], .string("m2"))
    let selectedMessages = try XCTUnwrap(jsonArray(normalizeOutput.payload["selectedMessages"]))
    let selectedMessage = try XCTUnwrap(jsonObject(selectedMessages.first))
    let files = try XCTUnwrap(jsonArray(selectedMessage["files"]))
    XCTAssertEqual(files.count, 3)
    XCTAssertTrue(files.contains { jsonObject($0)?["downloadKey"] == .string("attachment-key") })
    XCTAssertTrue(files.contains { jsonObject($0)?["downloadKey"] == .string("body-key") })

    let summaryPayload: JSONObject = [
      "messageDigests": .array([
        .object([
          "title": .string("Quarterly report"),
          "summary": .string("The report is ready."),
          "from": .string("Alice <alice@example.com>"),
          "messageIds": .array([.string("m2"), .string("missing")])
        ])
      ])
    ]
    let validateOutput = try await resolver.execute(
      gmailDigestInput(
        operation: "validate-summary-output",
        resolvedInputPayload: upstreamPayloads([normalizeOutput.payload, summaryPayload])
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(validateOutput.when["should_send_telegram"], true)
    XCTAssertEqual(validateOutput.payload["droppedInvalidMessageIdCount"], .number(1))
    XCTAssertTrue((string(validateOutput.payload["replyText"]) ?? "").contains("Quarterly report"))

    let persistOutput = try await resolver.execute(
      gmailDigestInput(
        operation: "persist-state",
        resolvedInputPayload: upstreamPayloads([readOutput.payload, validateOutput.payload]),
        variables: [
          "nowIso": .string("2026-06-23T04:05:00Z"),
          "workflowInput": .object(["stateFile": .string(stateFile)])
        ]
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(persistOutput.when["should_send_telegram"], true)
    XCTAssertEqual(persistOutput.payload["persisted"], .bool(true))
    let persisted = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: stateFile)))
    guard case let .object(state) = persisted else {
      return XCTFail("persisted state was not an object")
    }
    XCTAssertEqual(state["lastFetchedMessageId"], .string("m2"))
    XCTAssertEqual(state["seenMessageIds"], .array([.string("m2"), .string("m1")]))
    XCTAssertEqual(state["updatedAt"], .string("2026-06-23T04:05:00Z"))
  }

  func testGmailDigestAddonRejectsPublicStateFilePath() async throws {
    do {
      _ = try await BuiltinWorkflowAddonResolver(environment: [:]).execute(
        gmailDigestInput(
          operation: "read-state",
          variables: [
            "workflowInput": .object(["stateFile": .string("state.json")])
          ]
        ),
        context: AdapterExecutionContext()
      )
      XCTFail("expected public state path to be rejected")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertTrue(error.message.contains("ignored/private runtime path"))
    }
  }

  private func gmailDigestInput(
    operation: String,
    resolvedInputPayload: JSONObject = [:],
    variables: JSONObject = [:]
  ) -> WorkflowAddonExecutionInput {
    WorkflowAddonExecutionInput(
      workflowId: "gmail-latest-mail-digest-telegram",
      stepId: operation,
      nodeId: operation,
      addon: WorkflowNodeAddonRef(
        name: "riela/gmail-digest",
        version: "1",
        config: ["operation": .string(operation)]
      ),
      variables: variables,
      resolvedInputPayload: resolvedInputPayload
    )
  }

  private func upstreamPayloads(_ payloads: [JSONObject]) -> JSONObject {
    [
      "upstream": .array(payloads.map { payload in
        .object([
          "output": .object([
            "payload": .object(payload)
          ])
        ])
      })
    ]
  }

  private func message(
    id: String,
    subject: String,
    body: String,
    date: String,
    files: [JSONObject] = []
  ) -> JSONObject {
    [
      "id": .string(id),
      "threadId": .string("thread-\(id)"),
      "subject": .string(subject),
      "snippet": .string(body),
      "receivedAt": .string(date),
      "from": .object([
        "name": .string("Alice"),
        "address": .string("alice@example.com")
      ]),
      "to": .array([
        .object([
          "name": .string("Team"),
          "address": .string("team@example.com")
        ])
      ]),
      "textBody": .string(body),
      "files": .array(files.map(JSONValue.object))
    ]
  }

  private func thread(id: String, messages: [JSONObject]) -> JSONObject {
    [
      "id": .string(id),
      "accountId": .string("primary"),
      "subject": messages.first?["subject"] ?? .null,
      "snippet": messages.first?["snippet"] ?? .null,
      "messages": .array(messages.map(JSONValue.object))
    ]
  }

  private func string(_ value: JSONValue?) -> String? {
    guard case let .string(value)? = value else {
      return nil
    }
    return value
  }
}
