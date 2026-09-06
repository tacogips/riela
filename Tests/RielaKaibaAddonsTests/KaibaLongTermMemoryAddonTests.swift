import KaibaClient
import RielaAddonSupport
import RielaCore
import XCTest
@testable import RielaKaibaAddons

final class KaibaLongTermMemoryAddonTests: XCTestCase {
  func testEveryRegisteredMemoryAddonHasAnExactCompatibilityPayload() async throws {
    let client = try fixtureKaibaClient()
    let consolidateOutput = try await consolidate(
      client: client,
      config: ["idempotencyKey": .string("memory-shape")],
      payload: ["memoryEntries": .array([.object(["content": .string("# durable fact")])])]
    )
    XCTAssertEqual(
      Set(consolidateOutput.payload.keys),
      [
        "status", "addon", "operation", "stepId", "notebookId", "noteIds", "notes",
        "entriesWritten", "idempotentReplay", "idempotencyKey", "associations"
      ]
    )
    XCTAssertEqual(consolidateOutput.payload["entriesWritten"], .number(1))
    XCTAssertEqual(consolidateOutput.payload["idempotencyKey"], .string("memory-shape"))
    guard case let .array(notes)? = consolidateOutput.payload["notes"],
          case let .object(note)? = notes.first else {
      return XCTFail("expected a projected memory note")
    }
    XCTAssertEqual(
      Set(note.keys),
      ["noteId", "notebookId", "noteNumber", "title", "bodyMarkdown", "readOnly", "createdAt", "updatedAt", "metaJSON", "tags"]
    )
    XCTAssertNil(note["diagnostics"])
    XCTAssertNil(note["localPath"])

    let recallOutput = try await KaibaAddonCatalog.executeForTesting(
      .init(
        workflowId: "memory-test", stepId: "recall", nodeId: "recall",
        addon: .init(name: "kaiba/memory-recall", version: "1", config: ["query": .string("fixture")])
      ),
      client: client,
      environment: [:]
    )
    XCTAssertEqual(
      Set(recallOutput.payload.keys),
      [
        "status", "addon", "operation", "stepId", "query", "limit", "includeAssociations",
        "associationDepth", "results", "resultCount", "noteIds", "recallText"
      ]
    )
    XCTAssertEqual(recallOutput.payload["query"], .string("fixture"))
    guard case let .array(results)? = recallOutput.payload["results"],
          case let .object(result)? = results.first else {
      return XCTFail("expected a projected recall result")
    }
    XCTAssertEqual(
      Set(result.keys),
      ["noteId", "notebookId", "title", "bodyMarkdown", "snippet", "rank", "isAssociation", "edgeKind", "weight", "hopCount", "pathNoteIds", "createdAt", "metaJSON"]
    )
    XCTAssertNil(result["diagnostics"])
    XCTAssertNil(result["localPath"])
  }

  func testConsolidatePreservesCompatibilityFieldsAndRecordMetadata() async throws {
    let transport = KaibaHTTPFixture()
    let output = try await consolidate(
      client: fixtureKaibaClient(transport),
      config: ["idempotencyKey": .string("period-2026-08-01")],
      payload: ["memoryEntries": .array([.object([
        "content": .string("# durable fact"), "sourceMemoryRecordIds": .array([.integer(1), .string("two")])
      ])])]
    )
    XCTAssertEqual(output.payload["entriesWritten"], .number(1))
    XCTAssertEqual(output.payload["idempotencyKey"], .string("period-2026-08-01"))
    XCTAssertEqual(output.payload["noteIds"], .array([.string("note-1")]))
    XCTAssertNotNil(output.payload["associations"])
    let request = try XCTUnwrap(transport.requests.first)
    let requestText = String(bytes: request.body, encoding: .utf8) ?? ""
    XCTAssertTrue(requestText.contains("sourceMemoryRecordIds"))
    XCTAssertTrue(requestText.contains("period-2026-08-01"))
  }

  func testLostResponseReplayUsesTheSameAutomaticIdempotencyKey() async throws {
    let transport = KaibaHTTPFixture(lostResponseOperations: ["KaibaAppendLongTermMemory"])
    let client = try fixtureKaibaClient(transport)
    let payload: JSONObject = ["memoryEntries": .array([.object(["content": .string("# retry")])])]
    let initial = identity(step: "step-1", operation: "step-1", attempt: 1, predecessor: nil)
    let retry = identity(step: "step-2", operation: "step-1", attempt: 2, predecessor: "step-1")
    do {
      _ = try await consolidate(client: client, payload: payload, identity: initial)
      XCTFail("expected the committed request to lose its response")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .providerError)
    }
    let firstReplay = try await consolidate(client: client, payload: payload, identity: retry)
    let secondReplay = try await consolidate(client: client, payload: payload, identity: retry)
    XCTAssertEqual(firstReplay.payload["idempotencyKey"], secondReplay.payload["idempotencyKey"])
    XCTAssertEqual(firstReplay.payload["idempotentReplay"], .bool(true))
    XCTAssertEqual(secondReplay.payload["idempotentReplay"], .bool(true))
    let appendCount = transport.requests.filter {
      (String(bytes: $0.body, encoding: .utf8) ?? "").contains("KaibaAppendLongTermMemory")
    }.count
    XCTAssertEqual(appendCount, 3)
  }

  func testConsolidateFailsClosedWithoutIdentityWhenNoKeyIsProvided() async throws {
    do {
      _ = try await consolidate(client: fixtureKaibaClient(), payload: ["memoryEntries": .array([.object(["content": .string("# retry")])])])
      XCTFail("expected missing identity")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .invalidInput)
      XCTAssertEqual(error.message, "missing_idempotency_identity")
    }
  }

  func testRecallProducesPromptReadyCompatibilityPayload() async throws {
    let output = try await KaibaAddonCatalog.executeForTesting(
      .init(workflowId: "memory-test", stepId: "recall", nodeId: "recall", addon: .init(name: "kaiba/memory-recall", version: "1", config: ["query": .string("fixture")])),
      client: fixtureKaibaClient(),
      environment: [:]
    )
    XCTAssertEqual(output.payload["resultCount"], .number(1))
    XCTAssertEqual(output.payload["noteIds"], .array([.string("note-1")]))
    guard case let .string(recallText)? = output.payload["recallText"] else {
      return XCTFail("expected recall text")
    }
    XCTAssertTrue(recallText.contains("[direct]"))
  }

  private func consolidate(
    client: KaibaClient,
    config: JSONObject = [:],
    payload: JSONObject,
    identity: WorkflowAddonExecutionIdentity? = nil
  ) async throws -> AdapterExecutionOutput {
    try await KaibaAddonCatalog.executeForTesting(
      .init(
        workflowId: "memory-test", stepId: "consolidate", nodeId: "consolidate",
        addon: .init(name: "kaiba/memory-consolidate", version: "1", config: config),
        resolvedInputPayload: payload, executionIdentity: identity
      ),
      client: client,
      environment: [:]
    )
  }

  private func identity(step: String, operation: String, attempt: Int, predecessor: String?) -> WorkflowAddonExecutionIdentity {
    .init(workflowExecutionId: "execution", stepExecutionId: step, operationExecutionId: operation, attempt: attempt, predecessorStepExecutionId: predecessor, predecessorStepExecutionIds: predecessor.map { [$0] } ?? [])
  }
}
