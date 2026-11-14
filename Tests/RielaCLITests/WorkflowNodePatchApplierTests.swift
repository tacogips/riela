import RielaCore
import XCTest
@testable import RielaCLI

final class WorkflowNodePatchApplierTests: XCTestCase {
  func testRejectsModelChangeWhenNodeModelIsFrozen() throws {
    let applier = DefaultWorkflowNodePatchApplier()
    let nodePayloads = [
      "worker": AgentNodePayload(
        id: "worker",
        executionBackend: .codexAgent,
        model: "gpt-5",
        modelFreeze: true
      )
    ]

    XCTAssertThrowsError(try applier.applyNodePatch(
      ["worker": .object(["model": .string("gpt-5-mini")])],
      to: nodePayloads
    )) { error in
      XCTAssertEqual(error as? NodePatchError, .modelChangeFrozen("worker"))
    }

    let sameModel = try applier.applyNodePatch(
      ["worker": .object(["model": .string("gpt-5")])],
      to: nodePayloads
    )
    XCTAssertEqual(sameModel["worker"]?.model, "gpt-5")
  }
}
