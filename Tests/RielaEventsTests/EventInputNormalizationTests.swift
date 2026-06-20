import Foundation
import XCTest
@testable import RielaCore
@testable import RielaEvents

final class EventInputNormalizationTests: XCTestCase {
  func testDryRunAddsCanonicalEventInputWrapperAndChatPayload() async {
    let source = EventSourceContract(id: "chat-a", kind: .telegramGateway, provider: "telegram")
    let binding = EventBindingContract(
      id: "bind-a",
      sourceId: "chat-a",
      workflowName: "workflow-a",
      inputMapping: .init(mode: .eventInput)
    )
    let envelope = ExternalEventEnvelope(
      sourceId: "chat-a",
      eventId: "evt-1",
      provider: "telegram",
      eventType: "chat.message",
      receivedAt: Date(timeIntervalSince1970: 1),
      actor: ["id": .string("200"), "displayName": .string("Test User")],
      conversation: ["id": .string("100"), "threadId": .string("topic-a")],
      input: [
        "text": .string("hello"),
        "provider": .string("telegram"),
        "history": .array([.object(["text": .string("previous")])]),
        "attachments": .array([.object(["kind": .string("photo")])]),
        "imagePaths": .array([.string("/tmp/image.png")]),
        "attachmentText": .string("ocr text")
      ]
    )

    let result = await DeterministicEventDryRunTrigger().dryRun(.init(sources: [source], bindings: [binding], envelope: envelope))

    XCTAssertTrue(result.accepted)
    XCTAssertEqual(result.triggers.first?.input["text"], .string("hello"))
    XCTAssertEqual(result.triggers.first?.input["event_source_type"], .string("telegram-gateway"))
    guard case let .object(payload)? = result.triggers.first?.input["payload"] else {
      return XCTFail("expected canonical chat payload")
    }
    XCTAssertEqual(payload["text"], .string("hello"))
    XCTAssertEqual(payload["provider"], .string("telegram"))
    XCTAssertEqual(payload["history"], .array([.object(["text": .string("previous")])]))
    XCTAssertEqual(payload["attachments"], .array([.object(["kind": .string("photo")])]))
    XCTAssertEqual(payload["imagePaths"], .array([.string("/tmp/image.png")]))
    XCTAssertEqual(payload["attachmentText"], .string("ocr text"))
    XCTAssertEqual(payload["actor"], .object(["id": .string("200"), "displayName": .string("Test User")]))
    XCTAssertEqual(payload["conversation"], .object(["id": .string("100"), "threadId": .string("topic-a")]))

    guard case let .object(event)? = result.triggers.first?.runtimeVariables["event"],
      case let .object(eventInput)? = event["input"],
      case let .object(eventPayload)? = eventInput["payload"]
    else {
      return XCTFail("expected canonical event input")
    }
    XCTAssertEqual(eventInput["event_source_type"], .string("telegram-gateway"))
    XCTAssertEqual(eventPayload["text"], .string("hello"))
  }
}
