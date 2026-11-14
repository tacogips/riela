import Foundation
import RielaCore
import XCTest
@testable import RielaGraphQL

/// Contract-level coverage for the session mutations (CSP-5). The end-to-end
/// CLI/GraphQL lineage parity test lives in `RielaCLITests`, where the real
/// runner commands are reachable.
final class SessionMutationTests: XCTestCase {
  func testRerunResumeAndStopAreRoutedToTheProvider() async throws {
    let provider = RecordingSessionControlProvider()
    let executor = SessionControlGraphQLDocumentExecutor(provider: provider)

    let rerun = await executor.execute(Self.request(
      """
      mutation Rerun($input: RerunSessionInput!) {
        rerunSession(input: $input) { result { accepted } sessionId status lineage { entryMode sourceStepId } }
      }
      """,
      variables: ["input": .object([
        "workflowId": .string("workflow-a"),
        "sessionId": .string("session-a"),
        "stepId": .string("step-a")
      ])]
    ))
    XCTAssertTrue(rerun.handled)
    XCTAssertNil(rerun.body["errors"])
    let rerunStepIds = await provider.rerunInputs.map(\.stepId)
    XCTAssertEqual(rerunStepIds, ["step-a"])
    XCTAssertEqual(Self.string(rerun, path: ["rerunSession", "sessionId"]), "session-a-rerun")
    XCTAssertEqual(Self.string(rerun, path: ["rerunSession", "lineage", "entryMode"]), "rerun")

    let resume = await executor.execute(Self.request(
      "mutation Resume($input: ResumeSessionInput!) { resumeSession(input: $input) { sessionId status } }",
      variables: ["input": .object([
        "workflowId": .string("workflow-a"),
        "sessionId": .string("session-a")
      ])]
    ))
    XCTAssertEqual(Self.string(resume, path: ["resumeSession", "status"]), "completed")

    let stop = await executor.execute(Self.request(
      "mutation Stop($input: StopSessionInput!) { stopSession(input: $input) { sessionId status } }",
      variables: ["input": .object([
        "workflowId": .string("workflow-a"),
        "sessionId": .string("session-a")
      ])]
    ))
    XCTAssertEqual(Self.string(stop, path: ["stopSession", "status"]), "cancelled")
  }

  /// Delta D3: a session this process is not running fails closed.
  func testStoppingAnUnknownSessionReportsSessionNotRunning() async {
    let provider = RecordingSessionControlProvider(runningSessionIds: [])
    let executor = SessionControlGraphQLDocumentExecutor(provider: provider)
    let response = await executor.execute(Self.request(
      "mutation Stop($input: StopSessionInput!) { stopSession(input: $input) { sessionId } }",
      variables: ["input": .object([
        "workflowId": .string("workflow-a"),
        "sessionId": .string("missing")
      ])]
    ))
    XCTAssertTrue(response.handled)
    let message = Self.errorMessage(response)
    XCTAssertEqual(message, "session_not_running: missing")
    XCTAssertEqual(Self.errorCode(response), "SESSION_NOT_RUNNING")
  }

  /// Session control changes runtime state, so a document that is not locally
  /// trusted is rejected before the provider is reached.
  func testUntrustedDocumentsAreRejected() async {
    let provider = RecordingSessionControlProvider()
    let executor = SessionControlGraphQLDocumentExecutor(provider: provider)
    let response = await executor.execute(GraphQLDocumentRequest(
      query: "mutation Stop($input: StopSessionInput!) { stopSession(input: $input) { sessionId } }",
      variables: ["input": .object([
        "workflowId": .string("workflow-a"),
        "sessionId": .string("session-a")
      ])],
      isLocallyTrusted: false
    ))
    XCTAssertEqual(Self.errorCode(response), "SESSION_CONTROL_UNAVAILABLE")
    let attempted = await provider.stopInputs.count
    XCTAssertEqual(attempted, 0)
  }

  func testSessionControlFieldsAreRejectedAsQueries() async {
    let executor = SessionControlGraphQLDocumentExecutor(provider: RecordingSessionControlProvider())
    let response = await executor.execute(Self.request(
      "query Stop($input: StopSessionInput!) { stopSession(input: $input) { sessionId } }",
      variables: ["input": .object([
        "workflowId": .string("workflow-a"),
        "sessionId": .string("session-a")
      ])]
    ))
    XCTAssertEqual(Self.errorCode(response), "INVALID_SESSION_CONTROL")
  }

  func testUnrelatedFieldsFallThroughToTheNextExecutor() async {
    let executor = SessionControlGraphQLDocumentExecutor(
      provider: RecordingSessionControlProvider(),
      next: nil
    )
    let response = await executor.execute(Self.request(
      "query Config { configuration { profile } }"
    ))
    XCTAssertFalse(response.handled)
  }

  /// Every session mutation the catalog publishes must be one this executor
  /// handles. Session queries are served by the read services and are covered
  /// by `SurfaceParityExecutorCoverageTests`.
  func testExecutorCoversTheCatalogsSessionControlFields() {
    let declared = SurfaceCatalog.all
      .filter { $0.family == "session" && $0.kind == .mutation && $0.isImplemented(on: .graphql) }
      .compactMap { $0.graphql?.field }
    XCTAssertEqual(
      Set(declared),
      SessionControlGraphQLDocumentExecutor.mutationFields,
      "the catalog and the session-control executor disagree on the published fields"
    )
  }

  // MARK: - Helpers

  private static func request(_ query: String, variables: JSONObject = [:]) -> GraphQLDocumentRequest {
    GraphQLDocumentRequest(query: query, variables: variables, isLocallyTrusted: true)
  }

  private static func string(_ response: GraphQLDocumentExecutionResponse, path: [String]) -> String? {
    var value = response.body["data"]
    for key in path {
      guard case let .object(object)? = value else { return nil }
      value = object[key]
    }
    guard case let .string(result)? = value else { return nil }
    return result
  }

  private static func errorMessage(_ response: GraphQLDocumentExecutionResponse) -> String? {
    guard case let .array(errors)? = response.body["errors"],
          case let .object(first)? = errors.first,
          case let .string(message)? = first["message"] else { return nil }
    return message
  }

  private static func errorCode(_ response: GraphQLDocumentExecutionResponse) -> String? {
    guard case let .array(errors)? = response.body["errors"],
          case let .object(first)? = errors.first,
          case let .object(extensions)? = first["extensions"],
          case let .string(code)? = extensions["code"] else { return nil }
    return code
  }
}

private actor RecordingSessionControlProvider: GraphQLSessionControlProviding {
  private(set) var rerunInputs: [GraphQLRerunSessionInput] = []
  private(set) var resumeInputs: [GraphQLResumeSessionInput] = []
  private(set) var stopInputs: [GraphQLStopSessionInput] = []
  private let runningSessionIds: Set<String>

  init(runningSessionIds: Set<String> = ["session-a"]) {
    self.runningSessionIds = runningSessionIds
  }

  func rerunSession(_ input: GraphQLRerunSessionInput) async throws -> GraphQLSessionMutationPayload {
    rerunInputs.append(input)
    return GraphQLSessionMutationPayload(
      result: GraphQLControlPlaneResult(accepted: true, status: "found"),
      sessionId: "\(input.sessionId)-rerun",
      status: "completed",
      lineage: GraphQLSessionLineageDTO(
        sessionId: "\(input.sessionId)-rerun",
        parentSessionId: input.sessionId,
        rootSessionId: input.sessionId,
        entryMode: "rerun",
        sourceStepId: input.stepId
      )
    )
  }

  func resumeSession(_ input: GraphQLResumeSessionInput) async throws -> GraphQLSessionMutationPayload {
    resumeInputs.append(input)
    return GraphQLSessionMutationPayload(
      result: GraphQLControlPlaneResult(accepted: true, status: "found"),
      sessionId: input.sessionId,
      status: "completed",
      lineage: GraphQLSessionLineageDTO(
        sessionId: input.sessionId,
        rootSessionId: input.sessionId,
        entryMode: "resume"
      )
    )
  }

  func stopSession(_ input: GraphQLStopSessionInput) async throws -> GraphQLSessionMutationPayload {
    stopInputs.append(input)
    guard runningSessionIds.contains(input.sessionId) else {
      throw GraphQLSessionControlError.sessionNotRunning(input.sessionId)
    }
    return GraphQLSessionMutationPayload(
      result: GraphQLControlPlaneResult(accepted: true, status: "found"),
      sessionId: input.sessionId,
      status: "cancelled",
      lineage: nil
    )
  }

  func continueSession(_ input: GraphQLContinueSessionRequest) async throws -> GraphQLControlPlaneResult {
    GraphQLControlPlaneResult(accepted: true, status: "found")
  }
}
