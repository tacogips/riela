import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class LoopNotificationHandoverTests: XCTestCase {
  func testWebhookReceivesHandoverPayloadWithBoundedUTF8Brief() async throws {
    let transport = HandoverRecordingTransport()
    let dispatcher = LoopNotificationDispatcher(
      transport: transport,
      environment: ["HOOK_URL": "https://example.invalid/handover"],
      commandRunner: { _, _, _, _ in 0 }
    )
    let brief = String(repeating: "a", count: 2_047) + "😀"
    let payload = Self.payload(brief: brief)

    let diagnostics = await dispatcher.dispatchHandover(
      workflow: Self.workflow(on: ["handover"], channels: [
        LoopNotificationChannelDeclaration(type: "webhook", urlEnv: "HOOK_URL")
      ]),
      payload: payload,
      workflowDirectory: "/tmp/wf",
      workingDirectory: "/tmp"
    )

    let posts = await transport.posts
    XCTAssertEqual(posts.count, 1)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(posts.first?.body)) as? [String: Any])
    XCTAssertEqual(object["outcome"] as? String, "handover")
    XCTAssertEqual(object["workflowId"] as? String, "workflow-1")
    XCTAssertEqual(object["sessionId"] as? String, "session-1")
    XCTAssertEqual(object["taskId"] as? String, "task-1")
    XCTAssertEqual(object["handoverId"] as? String, "handover-1")
    XCTAssertEqual(object["reasonKind"] as? String, "userInputRequired")
    XCTAssertEqual(object["questionText"] as? String, "Which option should I use?")
    XCTAssertEqual(object["locators"] as? [String], ["file:/packet#sha256:" + String(repeating: "a", count: 64)])
    let briefHead = try XCTUnwrap(object["briefHead"] as? String)
    XCTAssertEqual(briefHead.utf8.count, 2_047)
    XCTAssertFalse(briefHead.contains("😀"))
    XCTAssertTrue(diagnostics.contains { $0.contains("delivered on attempt 1") })
  }

  func testUndeclaredHandoverNotificationDispatchesNothing() async {
    let transport = HandoverRecordingTransport()
    let dispatcher = LoopNotificationDispatcher(
      transport: transport,
      environment: ["HOOK_URL": "https://example.invalid/handover"],
      commandRunner: { _, _, _, _ in 0 }
    )
    let diagnostics = await dispatcher.dispatchHandover(
      workflow: Self.workflow(on: ["accepted"], channels: [
        LoopNotificationChannelDeclaration(type: "webhook", urlEnv: "HOOK_URL")
      ]),
      payload: Self.payload(brief: "brief"),
      workflowDirectory: "/tmp/wf",
      workingDirectory: "/tmp"
    )

    let posts = await transport.posts
    XCTAssertTrue(posts.isEmpty)
    XCTAssertTrue(diagnostics.isEmpty)
  }

  func testCommandChannelReceivesHandoverJSONOnStdin() async throws {
    let recorder = HandoverCommandRecorder()
    let dispatcher = LoopNotificationDispatcher(
      transport: HandoverRecordingTransport(),
      environment: [:],
      commandRunner: { argv, stdin, _, _ in
        await recorder.record(argv: argv, stdin: stdin)
        return 0
      }
    )
    let diagnostics = await dispatcher.dispatchHandover(
      workflow: Self.workflow(on: ["handover"], channels: [
        LoopNotificationChannelDeclaration(type: "command", argv: ["notify-handover", "--json"])
      ]),
      payload: Self.payload(brief: "handover brief"),
      workflowDirectory: "/tmp/wf",
      workingDirectory: "/tmp"
    )

    let calls = await recorder.calls
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(calls.first?.argv, ["notify-handover", "--json"])
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(calls.first?.stdin)) as? [String: Any])
    XCTAssertEqual(object["outcome"] as? String, "handover")
    XCTAssertEqual(object["briefHead"] as? String, "handover brief")
    XCTAssertTrue(diagnostics.contains { $0.contains("delivered on attempt 1") })
  }

  private struct RecordedPost: Sendable {
    var url: URL
    var body: Data
  }

  private actor HandoverRecordingTransport: LoopNotificationTransporting {
    private(set) var posts: [RecordedPost] = []

    func post(url: URL, bearerToken: String?, body: Data, timeoutSeconds: TimeInterval) async throws {
      posts.append(RecordedPost(url: url, body: body))
    }
  }

  private struct RecordedCommand: Sendable {
    var argv: [String]
    var stdin: Data
  }

  private actor HandoverCommandRecorder {
    private(set) var calls: [RecordedCommand] = []

    func record(argv: [String], stdin: Data) {
      calls.append(RecordedCommand(argv: argv, stdin: stdin))
    }
  }

  private static func workflow(on: [String], channels: [LoopNotificationChannelDeclaration]) -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "workflow-1",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
      entryStepId: "start",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "node", nodeFile: "node.json")],
      steps: [WorkflowStepRef(id: "start", nodeId: "node", role: .worker)],
      nodes: [WorkflowNodeRef(id: "node", nodeFile: "node.json")],
      loop: WorkflowLoopMetadata(notifications: LoopNotificationDeclaration(on: on, channels: channels))
    )
  }

  private static func payload(brief: String) -> HandoverNotificationPayload {
    HandoverNotificationPayload(
      workflowId: "workflow-1",
      sessionId: "session-1",
      taskId: "task-1",
      handoverId: "handover-1",
      reasonKind: "userInputRequired",
      questionText: "Which option should I use?",
      brief: brief,
      locators: ["file:/packet#sha256:" + String(repeating: "a", count: 64)]
    )
  }
}
