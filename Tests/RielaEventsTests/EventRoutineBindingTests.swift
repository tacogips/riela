import Foundation
import XCTest
import RielaCore
@testable import RielaEvents

final class EventRoutineBindingTests: XCTestCase {
  func testBindingDecodesRoutineFields() throws {
    let json = """
    {
      "id": "routine-a-binding",
      "sourceId": "routine-a-cron",
      "eventType": "cron.tick",
      "workflowName": "routine-task-runner",
      "inputMapping": {"mode": "event-input"},
      "routineId": "routine-a",
      "routineStoreRoot": "/tmp/routines"
    }
    """
    let binding = try JSONDecoder().decode(EventBindingContract.self, from: Data(json.utf8))
    XCTAssertEqual(binding.routineId, "routine-a")
    XCTAssertEqual(binding.routineStoreRoot, "/tmp/routines")

    let reencoded = try JSONDecoder().decode(
      EventBindingContract.self,
      from: JSONEncoder().encode(binding)
    )
    XCTAssertEqual(reencoded, binding)
  }

  func testBindingWithoutRoutineFieldsDecodesToNil() throws {
    let json = """
    {
      "id": "plain-binding",
      "sourceId": "some-source",
      "inputMapping": {"mode": "event-input"},
      "workflowName": "some-workflow"
    }
    """
    let binding = try JSONDecoder().decode(EventBindingContract.self, from: Data(json.utf8))
    XCTAssertNil(binding.routineId)
    XCTAssertNil(binding.routineStoreRoot)
  }

  func testRoutineCronBindingPassesContractValidation() {
    let source = EventSourceContract(id: "routine-a-cron", kind: .cron)
    let binding = EventBindingContract(
      id: "routine-a-binding",
      sourceId: "routine-a-cron",
      eventType: "cron.tick",
      workflowName: "routine-task-runner",
      inputMapping: EventInputMapping(
        mode: .template,
        template: .object([
          "routineId": .string("routine-a"),
          "task": .string("do the thing"),
          "scheduledAt": .string("{{event.input.scheduledAt}}")
        ]),
        mirrorToHumanInput: false
      ),
      routineId: "routine-a",
      routineStoreRoot: "/tmp/routines"
    )
    XCTAssertEqual(EventContractValidator.validate(sources: [source], bindings: [binding]), [])
  }
}
