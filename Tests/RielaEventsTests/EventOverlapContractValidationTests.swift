import Foundation
import XCTest
@testable import RielaCore
@testable import RielaEvents

final class EventOverlapContractValidationTests: XCTestCase {
  func testUnknownPolicyAndNonCronPolicyDiagnostics() {
    let unknown = validate(source: EventSourceContract(id: "cron", kind: .cron), binding: binding(overlapPolicy: "bogus"))
    XCTAssertEqual(unknown.map(\.message), ["overlapPolicy must be one of skip, cancelRunning, queue, concurrent; got 'bogus'"])

    let nonCron = validate(
      source: EventSourceContract(id: "web", kind: .webhook, routePath: "/hook"),
      binding: binding(sourceId: "web", overlapPolicy: "skip")
    )
    XCTAssertEqual(nonCron.map(\.message), ["overlapPolicy is only supported on bindings whose source kind is cron"])
  }

  func testCapsRequireMatchingPolicyAndPositiveValues() {
    let missingPolicy = validate(source: EventSourceContract(id: "cron", kind: .cron), binding: binding(maxQueuedRuns: 2))
    XCTAssertEqual(missingPolicy.map(\.message), ["maxQueuedRuns requires overlapPolicy queue on the same binding"])

    let invalidCap = validate(
      source: EventSourceContract(id: "cron", kind: .cron),
      binding: binding(overlapPolicy: "concurrent", maxConcurrentRuns: 0)
    )
    XCTAssertEqual(invalidCap.map(\.message), ["maxConcurrentRuns must be an integer >= 1"])
  }

  func testAbsentFieldsEncodeOmittedAndSettingsProject() throws {
    let emptyBinding = try JSONDecoder().decode(
      EventBindingContract.self,
      from: Data(#"{"id":"binding","sourceId":"cron","workflowName":"report","inputMapping":{"mode":"event-input"}}"#.utf8)
    )
    let encodedEmpty = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(emptyBinding)) as? [String: Any])
    XCTAssertNil(encodedEmpty["overlapPolicy"])
    XCTAssertNil(encodedEmpty["maxQueuedRuns"])
    XCTAssertNil(encodedEmpty["maxConcurrentRuns"])
    XCTAssertEqual(
      EventContractValidator.validate(sources: [EventSourceContract(id: "cron", kind: .cron)], bindings: [emptyBinding]),
      []
    )

    let decoded = try JSONDecoder().decode(
      EventBindingContract.self,
      from: Data(#"{"id":"binding","sourceId":"cron","workflowName":"report","inputMapping":{"mode":"event-input"},"overlapPolicy":"queue","maxQueuedRuns":2}"#.utf8)
    )
    XCTAssertEqual(decoded.overlapSettings, EventOverlapSettings(overlapPolicy: "queue", maxQueuedRuns: 2))
    let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
    XCTAssertEqual(encoded["overlapPolicy"] as? String, "queue")
    XCTAssertEqual(encoded["maxQueuedRuns"] as? Int, 2)
  }

  private func validate(source: EventSourceContract, binding: EventBindingContract) -> [EventValidationDiagnostic] {
    EventContractValidator.validate(sources: [source], bindings: [binding]).filter {
      $0.code == "INVALID_EVENT_OVERLAP_POLICY"
    }
  }

  private func binding(
    sourceId: String = "cron",
    overlapPolicy: String? = nil,
    maxQueuedRuns: Int? = nil,
    maxConcurrentRuns: Int? = nil
  ) -> EventBindingContract {
    EventBindingContract(
      id: "binding",
      sourceId: sourceId,
      workflowName: "report",
      inputMapping: EventInputMapping(mode: .eventInput),
      overlapPolicy: overlapPolicy,
      maxQueuedRuns: maxQueuedRuns,
      maxConcurrentRuns: maxConcurrentRuns
    )
  }
}
