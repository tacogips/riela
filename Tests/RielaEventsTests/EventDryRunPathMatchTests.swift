import Foundation
import XCTest
@testable import RielaCore
@testable import RielaEvents

final class EventDryRunPathMatchTests: XCTestCase {
  func testDryRunPathPrefixMatchesObjectKeyBoundary() async {
    let source = EventSourceContract(id: "web-a", kind: .webhook, provider: "web", routePath: "/hook")
    let siblingPrefix = EventBindingContract(
      id: "sibling-prefix",
      sourceId: "web-a",
      match: .init(eventType: "message", pathPrefix: "incoming/releases"),
      workflowName: "workflow-sibling",
      inputMapping: .init(mode: .eventInput)
    )
    let childPrefix = EventBindingContract(
      id: "child-prefix",
      sourceId: "web-a",
      match: .init(eventType: "message", pathPrefix: "incoming/releases-old"),
      workflowName: "workflow-child",
      inputMapping: .init(mode: .eventInput)
    )
    let envelope = ExternalEventEnvelope(
      sourceId: "web-a",
      eventId: "evt-1",
      provider: "web",
      eventType: "message",
      receivedAt: Date(timeIntervalSince1970: 1),
      input: ["file": .object(["path": .string("incoming/releases-old/build.zip")])]
    )

    let result = await DeterministicEventDryRunTrigger().dryRun(.init(
      sources: [source],
      bindings: [siblingPrefix, childPrefix],
      envelope: envelope
    ))

    XCTAssertEqual(result.triggers.map(\.bindingId), ["child-prefix"])
  }
}
