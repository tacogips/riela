#if os(macOS)
import Foundation
import RielaCore
import XCTest

final class RielaAppWebProjectionPolicyTests: XCTestCase {
  func testSafeSummaryFailsClosedForCredentialCanariesAndRedactsPaths() {
    let policy = WorkflowWebProjectionPolicy()
    for unsafe in [
      "SENTINEL_SECRET_MUST_NOT_RENDER",
      "Authorization: Bearer abc",
      "DATABASE_URL=postgres://user:pass@example.invalid/db",
      "-----BEGIN PRIVATE KEY----- value",
      "https://user:password@example.invalid/path",
      "request failed with " + ["sk", "live", "7Ta91Kp2Lm4N6Qr8"].joined(separator: "_")
    ] {
      XCTAssertEqual(policy.safeSummary(unsafe), "<redacted>")
    }
    XCTAssertEqual(
      policy.safeSummary("failed while reading /Users/example/private/file.json"),
      "failed while reading <path>"
    )
    XCTAssertEqual(policy.safeSummary("workflow validation failed"), "workflow validation failed")
    XCTAssertEqual(
      policy.persistedSummary("workflow validation failed", context: .diagnostic).value,
      "workflow validation failed"
    )
    for canary in [
      "hunter2",
      "correcthorsebatterystaple",
      "12345678",
      "unlabeled-value-7Ta91Kp2Lm4N6Qr8",
      "failed while reading /Users/example/private/file.json",
      "Authorization: Bearer abc"
    ] {
      XCTAssertEqual(
        policy.persistedSummary(canary, context: .diagnostic).value,
        "<redacted>"
      )
    }
    XCTAssertEqual(
      policy.persistedSummary("service returned hunter2", context: .stepFailure).value,
      "step failed"
    )
    XCTAssertEqual(
      policy.persistedSummary("correct horse battery staple", context: .gateFinding).value,
      "gate finding recorded"
    )
    XCTAssertEqual(
      policy.persistedSummary("12345678", context: .recoveryReason).value,
      "workflow recovery reason recorded"
    )
    XCTAssertEqual(
      policy.persistedSummary("lowercasesecret", context: .registryDiagnostic).value,
      "workflow registry diagnostic recorded"
    )
  }

  func testDefinitionRevisionIsExactByteSHA256() {
    XCTAssertEqual(
      WorkflowWebProjectionPolicy().contentRevision(Data("{}".utf8)),
      "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"
    )
  }

  func testRunDetailProjectionEnforcesSerializedResponseLimit() throws {
    let identifier = String(repeating: "x", count: 256)
    let event: JSONValue = .object([
      "sequence": .number(1),
      "at": .string(identifier),
      "eventType": .string(identifier),
      "channel": .string(identifier),
      "toolName": .string(identifier)
    ])
    let step: JSONValue = .object([
      "executionId": .string(identifier),
      "stepId": .string(identifier),
      "nodeId": .string(identifier),
      "events": .array(Array(repeating: event, count: 50)),
      "eventsTruncated": .bool(false)
    ])
    let input: JSONObject = [
      "steps": .array(Array(repeating: step, count: 256)),
      "diagnostics": .array(Array(repeating: .string(identifier), count: 100)),
      "gates": .array([]),
      "truncated": .bool(false)
    ]

    let bounded = try XCTUnwrap(WorkflowWebProjectionPolicy().boundedRunDetail(input))
    let encoded = try JSONEncoder().encode(JSONValue.object(bounded))
    XCTAssertLessThanOrEqual(encoded.count, WorkflowWebProjectionPolicy.runDetailResponseLimit)
    XCTAssertEqual(bounded["truncated"], .bool(true))
    guard case let .array(boundedSteps)? = bounded["steps"],
          case let .object(firstStep)? = boundedSteps.first else {
      return XCTFail("Expected bounded steps")
    }
    XCTAssertEqual(firstStep["eventsTruncated"], .bool(true))
  }

  func testDefinitionProjectionEnforcesSerializedResponseLimitAndMarkers() throws {
    let transition: JSONValue = .object([
      "toStepId": .string(String(repeating: "x", count: 256)),
      "label": .string(String(repeating: "y", count: 2_048))
    ])
    let step: JSONValue = .object([
      "id": .string("step"),
      "nodeId": .string("node"),
      "transitions": .array(Array(repeating: transition, count: 80))
    ])
    let input: JSONObject = [
      "definition": .object([
        "steps": .array(Array(repeating: step, count: 40)),
        "nodes": .array([])
      ]),
      "diagnostics": .array([]),
      "truncated": .bool(false)
    ]

    let bounded = try XCTUnwrap(WorkflowWebProjectionPolicy().boundedDefinition(input))
    let encoded = try JSONEncoder().encode(JSONValue.object(bounded))
    XCTAssertLessThanOrEqual(encoded.count, WorkflowWebProjectionPolicy.definitionResponseLimit)
    XCTAssertEqual(bounded["truncated"], .bool(true))
    guard case let .object(definition)? = bounded["definition"],
          case let .array(steps)? = definition["steps"],
          case let .object(firstStep)? = steps.first else {
      return XCTFail("Expected bounded definition steps")
    }
    XCTAssertEqual(firstStep["transitionsTruncated"], .bool(true))
  }
}
#endif
