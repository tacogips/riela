import XCTest
@testable import RielaCore

final class StepRetryPolicyValidationTests: XCTestCase {
  private func diagnostics(_ fields: [String: Any], addon: [String: Any]? = ["name": "riela/json-route"]) -> [WorkflowValidationDiagnostic] {
    var step: [String: Any] = ["id": "start", "nodeId": "node"]
    step.merge(fields) { _, new in new }
    var node: [String: Any] = ["id": "node"]
    if let addon { node["addon"] = addon } else { node["nodeFile"] = "nodes/node.json" }
    return validateRawAuthoredWorkflow([
      "workflowId": "retry-test", "defaults": ["nodeTimeoutMs": 900_000], "entryStepId": "start",
      "nodes": [node], "steps": [step]
    ])
  }

  private func assertPath(_ fields: [String: Any], _ suffix: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(diagnostics(fields).contains { $0.path == "workflow.steps[0].\(suffix)" }, "missing \(suffix)", file: file, line: line)
  }

  func testValidAndLegacyPolicies() {
    XCTAssertEqual(diagnostics([:]), [])
    XCTAssertEqual(diagnostics(["deadlineMs": 600_000]), [])
    XCTAssertEqual(diagnostics(["deadlineMs": 600_000, "timeoutMs": 180_000, "retry": [
      "maxAttempts": 4, "initialDelayMs": 2_000, "multiplier": 2, "maxDelayMs": 60_000, "jitter": "deterministic"
    ]]), [])
  }

  func testDeadlineBoundariesAndTypes() {
    for value: Any in [0, -1, 1.5, true, "600", 86_400_001, Double.infinity] {
      assertPath(["deadlineMs": value], "deadlineMs")
    }
  }

  func testRetryValuesAndUnknownFields() {
    for value: Any in [0, 11, true, 1.5] {
      assertPath(["deadlineMs": 600_000, "retry": ["maxAttempts": value]], "retry.maxAttempts")
    }
    assertPath(["deadlineMs": 600_000, "retry": [:]], "retry.maxAttempts")
    assertPath(["deadlineMs": 600_000, "retry": true], "retry")
    for value: Any in [0.5, Double.infinity, Double.nan, true] {
      assertPath(["deadlineMs": 600_000, "retry": ["maxAttempts": 2, "multiplier": value]], "retry.multiplier")
    }
    for field in ["initialDelayMs", "maxDelayMs"] {
      for value: Any in [-1, 3_600_001, 1.5, true] {
        assertPath(["deadlineMs": 600_000, "retry": ["maxAttempts": 2, field: value]], "retry.\(field)")
      }
    }
    assertPath(["deadlineMs": 600_000, "retry": ["maxAttempts": 2, "foo": 1]], "retry.foo")
    assertPath(["deadlineMs": 600_000, "retry": ["maxAttempts": 2, "jitter": "random"]], "retry.jitter")
    assertPath(["deadlineMs": 600_000, "retry": ["maxAttempts": 2, "initialDelayMs": 5_000, "maxDelayMs": 1_000]], "retry.maxDelayMs")
    assertPath(["deadlineMs": 600_000, "retry": ["maxAttempts": 2, "maxDelayMs": 999]], "retry.maxDelayMs")
  }

  func testCrossFieldRules() {
    assertPath(["retry": ["maxAttempts": 2]], "retry")
    assertPath(["deadlineMs": 600_000, "timeoutMs": 700_000], "timeoutMs")
    let placement: [String: Any] = ["workspace": "ws", "target": [String: Any]()]
    for fields: [String: Any] in [
      ["deadlineMs": 600_000, "retry": ["maxAttempts": 2], "placement": placement],
      ["deadlineMs": 600_000, "placement": placement]
    ] {
      XCTAssertTrue(diagnostics(fields).contains {
        $0.path == "workflow.steps[0].placement" && $0.message == "cannot be combined with deadlineMs or retry"
      })
    }
    XCTAssertFalse(diagnostics(["placement": placement]).contains {
      $0.message.contains("deadlineMs") || $0.message.contains("retry")
    })
    XCTAssertTrue(diagnostics(["deadlineMs": 600_000], addon: nil).contains { $0.path == "workflow.steps[0].deadlineMs" })
    let addon: [String: Any] = ["name": "riela/json-route", "config": ["writeRetry": [:]]]
    XCTAssertTrue(diagnostics(["deadlineMs": 600_000, "retry": ["maxAttempts": 2]], addon: addon)
      .contains { $0.path == "workflow.steps[0].retry" && $0.message.contains("nested retry") })
    XCTAssertFalse(diagnostics(["deadlineMs": 600_000], addon: addon).contains { $0.path == "workflow.steps[0].retry" })
  }

  func testMalformedNodeIdentifiersDoNotResolveAddon() {
    for nodeId: Any? in [nil, true] {
      var step: [String: Any] = ["id": "start", "deadlineMs": 100]
      if let nodeId { step["nodeId"] = nodeId }
      var diagnostics: [WorkflowValidationDiagnostic] = []
      validateStepDeadlineAndRetry(step, path: "workflow.steps[0]", nodeEntries: [
        ["addon": ["name": "riela/json-route"]], ["id": true, "addon": ["name": "riela/json-route"]]
      ], diagnostics: &diagnostics)
      XCTAssertTrue(diagnostics.contains {
        $0.path == "workflow.steps[0].deadlineMs" && $0.message == "is supported only on add-on-backed steps"
      })
    }
  }
}
