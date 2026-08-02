import Foundation
import RielaCore
@testable import RielaCLI
import XCTest

final class EventLiveServeMatrixTests: XCTestCase {
  func testMatrixServeSyncsRunsWorkflowSendsReplyAndPersistsSinceToken() async throws {
    let eventRoot = try temporaryDirectory()
    try writeMatrixEventConfig(eventRoot: eventRoot)
    let api = FakeMatrixGatewayAPI(responses: [MatrixSyncResponse(
      nextBatch: "sync-2",
      rooms: MatrixSyncRooms(join: [
        "!room:localhost": MatrixJoinedRoom(timeline: MatrixRoomTimeline(events: [
          MatrixRoomEvent(
            type: "m.room.message",
            eventId: "$event-1",
            sender: "@alice:localhost",
            originServerTimestamp: 1_000,
            content: MatrixMessageContent(body: "Yui, hello", messageType: "m.text", relatesTo: nil)
          )
        ]))
      ]))
    ])
    let workflowRunner = FakeEventWorkflowRunner(replyText: "Matrix reply", replyAs: "yui")
    let server = DefaultEventLiveServer(matrixAPI: api, workflowRunner: workflowRunner)

    let result = try await CLIRuntimeEnvironment.$overrides.withValue([
      "TEST_MATRIX_HOMESERVER": "https://matrix.example",
      "TEST_MATRIX_TOKEN": "source-token",
      "TEST_MATRIX_YUI_TOKEN": "yui-token"
    ]) {
      try await server.serve(
        eventRoot: eventRoot,
        target: nil,
        parsed: try ParsedParityOptions(["--limit", "1"]),
        output: .json
      )
    }

    XCTAssertEqual(result.status, "ok")
    XCTAssertTrue(result.records.contains("processedEvents=1"))
    let workflowRequests = await workflowRunner.requests
    XCTAssertEqual(workflowRequests.map(\.workflowName), ["matrix-flow"])
    XCTAssertEqual(workflowRequests.first?.runtimeVariables["humanInput"], .object([
      "request": .string("Yui, hello"),
      "conversationId": .string("!room:localhost")
    ]))
    let sentMessages = await api.sentMessages
    XCTAssertEqual(sentMessages.count, 1)
    XCTAssertEqual(sentMessages.first?.homeserverURL.absoluteString, "https://matrix.example")
    XCTAssertEqual(sentMessages.first?.accessToken, "yui-token")
    XCTAssertEqual(sentMessages.first?.roomId, "!room:localhost")
    XCTAssertEqual(sentMessages.first?.text, "Matrix reply")
    XCTAssertNil(sentMessages.first?.threadEventId)
    let sinceData = try Data(contentsOf: eventRoot.appendingPathComponent("matrix/test-sync.json"))
    XCTAssertEqual(try JSONDecoder().decode(MatrixTestSinceRecord.self, from: sinceData).since, "sync-2")
  }

  func testMatrixServeIgnoresOwnMessagesAndPreservesThreadReplies() async throws {
    let eventRoot = try temporaryDirectory()
    try writeMatrixEventConfig(eventRoot: eventRoot)
    let api = FakeMatrixGatewayAPI(responses: [MatrixSyncResponse(
      nextBatch: "sync-3",
      rooms: MatrixSyncRooms(join: [
        "!room:localhost": MatrixJoinedRoom(timeline: MatrixRoomTimeline(events: [
          MatrixRoomEvent(
            type: "m.room.message",
            eventId: "$own",
            sender: "@riela:localhost",
            originServerTimestamp: 1_000,
            content: MatrixMessageContent(body: "ignore me", messageType: "m.text", relatesTo: nil)
          ),
          MatrixRoomEvent(
            type: "m.room.message",
            eventId: "$thread",
            sender: "@alice:localhost",
            originServerTimestamp: 2_000,
            content: MatrixMessageContent(
              body: "thread question",
              messageType: "m.text",
              relatesTo: MatrixEventRelation(relType: "m.thread", eventId: "$root")
            )
          )
        ]))
      ]))
    ])
    let workflowRunner = FakeEventWorkflowRunner(replyText: "thread reply", replyAs: "yui")
    let server = DefaultEventLiveServer(matrixAPI: api, workflowRunner: workflowRunner)

    _ = try await CLIRuntimeEnvironment.$overrides.withValue([
      "TEST_MATRIX_HOMESERVER": "https://matrix.example",
      "TEST_MATRIX_TOKEN": "source-token",
      "TEST_MATRIX_YUI_TOKEN": "yui-token"
    ]) {
      try await server.serve(
        eventRoot: eventRoot,
        target: nil,
        parsed: try ParsedParityOptions(["--limit", "1"]),
        output: .json
      )
    }

    let workflowRequests = await workflowRunner.requests
    XCTAssertEqual(workflowRequests.count, 1)
    XCTAssertEqual(eventInput(from: try XCTUnwrap(workflowRequests.first))?["text"], .string("thread question"))
    let sentMessages = await api.sentMessages
    XCTAssertEqual(sentMessages.count, 1)
    XCTAssertEqual(sentMessages.first?.threadEventId, "$root")
  }

  func testMatrixServeRejectsSinceTokenPathOutsideEventRoot() async throws {
    let eventRoot = try temporaryDirectory()
    try writeMatrixEventConfig(eventRoot: eventRoot, sinceTokenPath: "../outside.json")
    let api = FakeMatrixGatewayAPI(responses: [])
    let server = DefaultEventLiveServer(matrixAPI: api, workflowRunner: FakeEventWorkflowRunner(replies: []))

    do {
      _ = try await CLIRuntimeEnvironment.$overrides.withValue([
        "TEST_MATRIX_HOMESERVER": "https://matrix.example",
        "TEST_MATRIX_TOKEN": "source-token",
        "TEST_MATRIX_YUI_TOKEN": "yui-token"
      ]) {
        try await server.serve(
          eventRoot: eventRoot,
          target: nil,
          parsed: try ParsedParityOptions(["--limit", "1"]),
          output: .json
        )
      }
      XCTFail("expected an unsafe sinceTokenPath to fail")
    } catch {
      XCTAssertTrue(String(describing: error).contains("event-root-relative"))
    }
    let syncRequests = await api.syncRequests
    XCTAssertTrue(syncRequests.isEmpty)
  }

  func testMatrixServeDownloadsTextAttachmentAndReloadsBoundedHistory() async throws {
    let eventRoot = try temporaryDirectory()
    try writeMatrixEventConfig(eventRoot: eventRoot)
    let now = Int64(Date().timeIntervalSince1970 * 1_000)
    let attachmentURL = "mxc://localhost/file-1"
    let firstAPI = FakeMatrixGatewayAPI(
      responses: [MatrixSyncResponse(
        nextBatch: "sync-history-1",
        rooms: MatrixSyncRooms(join: [
          "!room:localhost": MatrixJoinedRoom(timeline: MatrixRoomTimeline(events: [
            MatrixRoomEvent(
              type: "m.room.message",
              eventId: "$history-1",
              sender: "@alice:localhost",
              originServerTimestamp: now,
              content: MatrixMessageContent(body: "first message", messageType: "m.text", relatesTo: nil)
            ),
            MatrixRoomEvent(
              type: "m.room.message",
              eventId: "$history-2",
              sender: "@alice:localhost",
              originServerTimestamp: now + 1,
              content: MatrixMessageContent(
                body: "notes.md",
                messageType: "m.file",
                filename: "notes.md",
                url: attachmentURL,
                info: MatrixAttachmentInfo(mimeType: "text/markdown", size: 12),
                relatesTo: nil
              )
            )
          ]))
        ]))
      ],
      attachmentDataByURL: [attachmentURL: Data("matrix notes".utf8)]
    )
    let firstRunner = FakeEventWorkflowRunner(replies: ["first reply", "second reply"], replyAs: "yui")
    let firstServer = DefaultEventLiveServer(matrixAPI: firstAPI, workflowRunner: firstRunner)

    _ = try await withMatrixTestEnvironment {
      try await firstServer.serve(
        eventRoot: eventRoot,
        target: nil,
        parsed: try ParsedParityOptions(["--limit", "2"]),
        output: .json
      )
    }

    let firstRequests = await firstRunner.requests
    XCTAssertEqual(firstRequests.count, 2)
    let secondInput = try XCTUnwrap(eventInput(from: firstRequests[1]))
    XCTAssertEqual(secondInput["attachmentText"], .string("matrix notes"))
    guard case let .array(attachments)? = secondInput["attachments"],
      case let .object(descriptor)? = attachments.first
    else {
      return XCTFail("expected one normalized Matrix attachment")
    }
    let attachmentPath = try XCTUnwrap(descriptor["path"]?.stringValue)
    XCTAssertTrue(FileManager.default.fileExists(atPath: attachmentPath))
    guard case let .array(secondHistory)? = secondInput["history"] else {
      return XCTFail("expected persisted history on the second message")
    }
    XCTAssertEqual(secondHistory.count, 2)

    let secondAPI = FakeMatrixGatewayAPI(responses: [MatrixSyncResponse(
      nextBatch: "sync-history-2",
      rooms: MatrixSyncRooms(join: [
        "!room:localhost": MatrixJoinedRoom(timeline: MatrixRoomTimeline(events: [
          MatrixRoomEvent(
            type: "m.room.message",
            eventId: "$history-3",
            sender: "@alice:localhost",
            originServerTimestamp: now + 2,
            content: MatrixMessageContent(body: "after restart", messageType: "m.text", relatesTo: nil)
          )
        ]))
      ]))
    ])
    let secondRunner = FakeEventWorkflowRunner(replyText: "restart reply", replyAs: "yui")
    let secondServer = DefaultEventLiveServer(matrixAPI: secondAPI, workflowRunner: secondRunner)
    _ = try await withMatrixTestEnvironment {
      try await secondServer.serve(
        eventRoot: eventRoot,
        target: nil,
        parsed: try ParsedParityOptions(["--limit", "1"]),
        output: .json
      )
    }
    let restartRequests = await secondRunner.requests
    let restartInput = try XCTUnwrap(eventInput(from: try XCTUnwrap(restartRequests.first)))
    guard case let .array(reloadedHistory)? = restartInput["history"] else {
      return XCTFail("expected history after event runner restart")
    }
    XCTAssertEqual(reloadedHistory.count, 3)
  }

  private func temporaryDirectory() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("riela-event-live-matrix-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: root)
    }
    return root
  }

  private func withMatrixTestEnvironment<T: Sendable>(
    operation: () async throws -> T
  ) async rethrows -> T {
    try await CLIRuntimeEnvironment.$overrides.withValue([
      "TEST_MATRIX_HOMESERVER": "https://matrix.example",
      "TEST_MATRIX_TOKEN": "source-token",
      "TEST_MATRIX_YUI_TOKEN": "yui-token"
    ]) {
      try await operation()
    }
  }

  private func writeMatrixEventConfig(
    eventRoot: URL,
    sinceTokenPath: String = "matrix/test-sync.json"
  ) throws {
    let sources = eventRoot.appendingPathComponent("sources", isDirectory: true)
    let bindings = eventRoot.appendingPathComponent("bindings", isDirectory: true)
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bindings, withIntermediateDirectories: true)
    try """
    {
      "id": "matrix-live",
      "kind": "matrix",
      "provider": "matrix",
      "homeserverUrlEnv": "TEST_MATRIX_HOMESERVER",
      "accessTokenEnv": "TEST_MATRIX_TOKEN",
      "userId": "@riela:localhost",
      "rooms": [{"roomId": "!room:localhost"}],
      "sync": {"pollTimeoutMs": 0, "sinceTokenPath": "\(sinceTokenPath)"},
      "history": {"maxMessages": 3, "maxBytes": 65536, "maxAgeMs": 2592000000, "scope": "thread-or-room"},
      "attachments": {"downloadText": true, "maxBytes": 65536, "allowedMimeTypes": ["text/plain", "text/markdown", "application/json"]},
      "replyBots": {"yui": {"accessTokenEnv": "TEST_MATRIX_YUI_TOKEN"}}
    }
    """.write(to: sources.appendingPathComponent("matrix-live.json"), atomically: true, encoding: .utf8)
    try """
    {
      "id": "matrix-to-workflow",
      "sourceId": "matrix-live",
      "workflowName": "matrix-flow",
      "match": {"eventType": "chat.message"},
      "inputMapping": {
        "mode": "template",
        "template": {
          "request": "{{event.input.text}}",
          "conversationId": "{{event.conversation.id}}"
        },
        "mirrorToHumanInput": true
      }
    }
    """.write(to: bindings.appendingPathComponent("matrix-to-workflow.json"), atomically: true, encoding: .utf8)
  }
}

private struct MatrixTestSinceRecord: Decodable {
  var since: String
}
