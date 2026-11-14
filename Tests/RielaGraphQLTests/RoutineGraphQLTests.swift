import Foundation
import XCTest
import RielaCore
@testable import RielaGraphQL

private struct StubRoutineProvider: RoutineGraphQLProviding {
  var record: RoutineRecord {
    RoutineRecord(
      routineId: "routine-a",
      name: "daily digest",
      task: "summarize inbox",
      schedule: "0 */30 * * * *",
      workflowName: "routine-task-runner",
      createdAt: "2026-09-03T00:00:00.000Z",
      updatedAt: "2026-09-03T00:00:00.000Z",
      eventRoot: "/tmp/events",
      sourceId: "routine-a-cron",
      bindingId: "routine-a-binding"
    )
  }

  func routines(filter: GraphQLRoutineFilterInput?) async throws -> [GraphQLRoutine] {
    [GraphQLRoutine(record)]
  }

  func routine(routineId: String, routineStoreRoot: String?) async throws -> GraphQLRoutine {
    guard routineId == "routine-a" else {
      throw RoutineGraphQLError(code: "INVALID_ROUTINE", message: "routine '\(routineId)' was not found")
    }
    return GraphQLRoutine(record)
  }

  func createRoutine(input: GraphQLCreateRoutineInput) async throws -> GraphQLRoutineMutationPayload {
    GraphQLRoutineMutationPayload(accepted: true, routine: GraphQLRoutine(record), diagnostics: ["created"])
  }

  func completeRoutine(input: GraphQLCompleteRoutineInput) async throws -> GraphQLRoutineMutationPayload {
    var completed = record
    completed.status = .completed
    return GraphQLRoutineMutationPayload(accepted: true, routine: GraphQLRoutine(completed))
  }

  func setRoutineStatus(input: GraphQLSetRoutineStatusInput) async throws -> GraphQLRoutineMutationPayload {
    GraphQLRoutineMutationPayload(accepted: true, routine: GraphQLRoutine(record))
  }

  func deleteRoutine(input: GraphQLDeleteRoutineInput) async throws -> GraphQLRoutineMutationPayload {
    GraphQLRoutineMutationPayload(accepted: true)
  }
}

final class RoutineGraphQLTests: XCTestCase {
  func testSchemaContractCarriesRoutineFields() {
    let schema = GraphQLContractProjector.schemaContract
    XCTAssertTrue(schema.contains("enum RoutineStatus { ACTIVE, DISABLED, COMPLETED }"))
    XCTAssertTrue(schema.contains("routines(filter: RoutineFilter): RoutineListPayload!"))
    XCTAssertTrue(schema.contains("routine(routineId: String!, routineStoreRoot: String): RoutineQueryPayload!"))
    XCTAssertTrue(schema.contains("createRoutine(input: CreateRoutineInput!): RoutineMutationPayload!"))
    XCTAssertTrue(schema.contains("completeRoutine(input: CompleteRoutineInput!): RoutineMutationPayload!"))
    XCTAssertTrue(schema.contains("setRoutineStatus(input: SetRoutineStatusInput!): RoutineMutationPayload!"))
    XCTAssertTrue(schema.contains("deleteRoutine(input: DeleteRoutineInput!): RoutineMutationPayload!"))
    XCTAssertTrue(schema.contains("input CreateRoutineInput"))
  }

  func testRoutinesQueryExecutesAgainstProvider() async throws {
    let executor = RoutineGraphQLDocumentExecutor(provider: StubRoutineProvider())
    let response = await executor.execute(GraphQLDocumentRequest(
      query: "{ routines { routines { routineId name status } errors { code } } }",
      variables: [:],
      operationName: nil,
      environment: [:],
      isLocallyTrusted: true
    ))
    XCTAssertTrue(response.handled)
    guard case let .object(data)? = response.body["data"],
          case let .object(payload)? = data["routines"],
          case let .array(routines)? = payload["routines"],
          case let .object(routine)? = routines.first
    else {
      return XCTFail("unexpected response shape: \(response.body)")
    }
    XCTAssertEqual(routine["routineId"], .string("routine-a"))
    XCTAssertEqual(routine["status"], .string("ACTIVE"))
    XCTAssertNil(response.body["errors"])
  }

  func testCreateRoutineMutationExecutesAgainstProvider() async throws {
    let executor = RoutineGraphQLDocumentExecutor(provider: StubRoutineProvider())
    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation {
        createRoutine(input: {name: "daily digest", task: "summarize inbox", every: "30m", workflowName: "routine-task-runner"}) {
          accepted
          routine { routineId }
          diagnostics
        }
      }
      """,
      variables: [:],
      operationName: nil,
      environment: [:],
      isLocallyTrusted: true
    ))
    XCTAssertTrue(response.handled)
    guard case let .object(data)? = response.body["data"],
          case let .object(payload)? = data["createRoutine"]
    else {
      return XCTFail("unexpected response shape: \(response.body)")
    }
    XCTAssertEqual(payload["accepted"], .bool(true))
    XCTAssertEqual(payload["diagnostics"], .array([.string("created")]))
  }

  func testRoutineDomainRefusesUntrustedRequests() async {
    let executor = RoutineGraphQLDocumentExecutor(provider: StubRoutineProvider())
    let response = await executor.execute(GraphQLDocumentRequest(
      query: "{ routines { routines { routineId } } }",
      variables: [:],
      operationName: nil,
      environment: [:],
      isLocallyTrusted: false
    ))
    XCTAssertTrue(response.handled)
    XCTAssertNotNil(response.body["errors"])
  }

  func testUnrelatedDocumentIsNotHandled() async {
    let executor = RoutineGraphQLDocumentExecutor(provider: StubRoutineProvider())
    let response = await executor.execute(GraphQLDocumentRequest(
      query: "{ workflows { workflows { workflowId } } }",
      variables: [:],
      operationName: nil,
      environment: [:],
      isLocallyTrusted: true
    ))
    XCTAssertFalse(response.handled)
  }
}
