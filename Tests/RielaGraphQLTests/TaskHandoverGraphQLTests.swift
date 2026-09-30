import Foundation
import XCTest
import RielaCore
@testable import RielaGraphQL

private actor StubTaskHandoverProvider: TaskHandoverGraphQLProviding {
  private(set) var calls: [String] = []
  var failure: TaskHandoverGraphQLError?

  init(failure: TaskHandoverGraphQLError? = nil) { self.failure = failure }

  private func record(_ call: String) throws {
    calls.append(call)
    if let failure { throw failure }
  }

  func recordedCalls() -> [String] { calls }

  func taskHandover(taskId: String, handoverId: String?, context: GraphQLDocumentRequest) async throws -> GraphQLHandoverPacket? {
    try record("taskHandover:\(taskId):\(handoverId ?? "latest")")
    return GraphQLHandoverPacket(handoverId: "h-1", taskId: taskId, digest: "sha256", reasonKind: "answer", resumeStepId: "resume", brief: "brief", packet: ["taskId": .string(taskId)])
  }

  func tasksAwaitingHandover(traits: [String]?, context: GraphQLDocumentRequest) async throws -> [GraphQLTaskHandoverSummary] {
    try record("tasksAwaitingHandover:\((traits ?? []).joined(separator: ","))")
    return [GraphQLTaskHandoverSummary(taskId: "t-1", handoverId: "h-1", reasonKind: "answer", requiredTraits: traits ?? [], needsAnswer: true, questionText: "confirm?", createdAt: "now")]
  }

  func requestTaskHandover(_ input: GraphQLRequestTaskHandoverInput, context: GraphQLDocumentRequest) async throws -> GraphQLTaskHandoverMutationPayload {
    try record("requestTaskHandover:\(input.taskId):\(input.reason):\(input.immediate ?? false)")
    return GraphQLTaskHandoverMutationPayload(taskId: input.taskId, taskState: "waiting", requestId: "r-1")
  }

  func answerTask(_ input: GraphQLAnswerTaskInput, context: GraphQLDocumentRequest) async throws -> GraphQLTaskHandoverMutationPayload {
    try record("answerTask:\(input.taskId):\(input.questionId):\(input.answer["value"] ?? .null)")
    return GraphQLTaskHandoverMutationPayload(taskId: input.taskId, taskState: "ready", decisionKind: "answer")
  }

  func takeoverTask(_ input: GraphQLTakeoverTaskInput, context: GraphQLDocumentRequest) async throws -> GraphQLTakeoverTaskPayload {
    try record("takeoverTask:\(input.taskId):\(input.handoverId):\(input.hostId):\(input.traits.joined(separator: ","))")
    return GraphQLTakeoverTaskPayload(attemptId: "a-2", sessionId: "s-2", fence: 2, expiresAt: "later", heartbeatToken: "token", heartbeatMs: 15000)
  }

  func heartbeatAttempt(attemptId: String, token: String, context: GraphQLDocumentRequest) async throws -> GraphQLLeaseStatePayload {
    try record("heartbeatAttempt:\(attemptId):\(token)")
    return GraphQLLeaseStatePayload(attemptId: attemptId, fence: 2, expiresAt: "later", fenced: false)
  }

  func reportAttempt(_ input: GraphQLReportAttemptInput, context: GraphQLDocumentRequest) async throws -> GraphQLReportAttemptPayload {
    try record("reportAttempt:\(input.attemptId):\(input.token):\(input.deliverables.count)")
    return GraphQLReportAttemptPayload(attemptId: input.attemptId, taskState: "succeeded", decisionKind: "complete")
  }
}

private final class RecordingNextExecutor: GraphQLDocumentExecuting, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [String] = []
  private let response: GraphQLDocumentExecutionResponse

  init(response: GraphQLDocumentExecutionResponse) { self.response = response }

  var queries: [String] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  private func record(_ query: String) {
    lock.lock()
    defer { lock.unlock() }
    recorded.append(query)
  }

  func execute(_ request: GraphQLDocumentRequest) async -> GraphQLDocumentExecutionResponse {
    record(request.query)
    return response
  }
}

private final class PreflightingNextExecutor: GraphQLDocumentExecuting, GraphQLDocumentDomainPreflighting, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [[String]] = []
  private let rejection: GraphQLDocumentExecutionResponse?

  init(rejection: GraphQLDocumentExecutionResponse? = nil) { self.rejection = rejection }

  var preflightedRoots: [[String]] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func execute(_ request: GraphQLDocumentRequest) async -> GraphQLDocumentExecutionResponse { .notHandled }

  private func record(_ roots: [String]) {
    lock.lock()
    defer { lock.unlock() }
    recorded.append(roots)
  }

  func preflight(_ request: GraphQLDocumentRequest, rootFields: [ParsedGraphQLRootField]) async -> GraphQLDocumentExecutionResponse? {
    record(rootFields.map(\.fieldName))
    return rejection
  }
}

private func parsedRoots(_ query: String) throws -> [ParsedGraphQLRootField] {
  let operations = try parseGraphQLOperations(in: query, operationName: nil, variables: [:], parseArguments: true)
  return try XCTUnwrap(selectGraphQLOperation(operations, operationName: nil)).rootFields
}

private func handoverTestRejection(code: String) -> GraphQLDocumentExecutionResponse {
  GraphQLDocumentExecutionResponse(handled: true, body: ["data": .null, "errors": .array([.object([
    "message": .string("rejected"), "extensions": .object(["code": .string(code)])
  ])])])
}

private func errorCode(_ response: GraphQLDocumentExecutionResponse?) -> JSONValue? {
  guard case let .array(errors)? = response?.body["errors"], case let .object(error)? = errors.first,
        case let .object(extensions)? = error["extensions"] else { return nil }
  return extensions["code"]
}

final class TaskHandoverGraphQLTests: XCTestCase {
  func testSevenOperationsRouteDecodedArgumentsToProvider() async throws {
    let provider = StubTaskHandoverProvider()
    let executor = TaskHandoverGraphQLDocumentExecutor(provider: provider)
    let docs: [(query: String, data: JSONValue)] = [
      (
        "{ taskHandover(taskId: \"t-1\", handoverId: \"h-1\") { handover { taskId digest resumeStepId } } }",
        .object(["taskHandover": .object(["handover": .object([
          "taskId": .string("t-1"), "digest": .string("sha256"), "resumeStepId": .string("resume")
        ])])])
      ),
      (
        "{ tasksAwaitingHandover(traits: [\"userReachable\"]) { tasks { taskId needsAnswer requiredTraits } } }",
        .object(["tasksAwaitingHandover": .object(["tasks": .array([.object([
          "taskId": .string("t-1"), "needsAnswer": .bool(true), "requiredTraits": .array([.string("userReachable")])
        ])])])])
      ),
      (
        "mutation { requestTaskHandover(input: {taskId: \"t-1\", reason: \"move\", immediate: true}) { taskId requestId } }",
        .object(["requestTaskHandover": .object(["taskId": .string("t-1"), "requestId": .string("r-1")])])
      ),
      (
        "mutation { answerTask(input: {taskId: \"t-1\", questionId: \"q-1\", answer: {value: \"yes\"}}) { decisionKind } }",
        .object(["answerTask": .object(["decisionKind": .string("answer")])])
      ),
      (
        "mutation { takeoverTask(input: {taskId: \"t-1\", handoverId: \"h-1\", hostId: \"host\", traits: [\"userReachable\"]}) { attemptId fence heartbeatToken heartbeatMs } }",
        .object(["takeoverTask": .object([
          "attemptId": .string("a-2"), "fence": .integer(2), "heartbeatToken": .string("token"), "heartbeatMs": .integer(15000)
        ])])
      ),
      (
        "mutation { heartbeatAttempt(attemptId: \"a-2\", token: \"token\") { fenced fence } }",
        .object(["heartbeatAttempt": .object(["fenced": .bool(false), "fence": .integer(2)])])
      ),
      (
        "mutation { reportAttempt(input: {attemptId: \"a-2\", token: \"token\", snapshot: {}, deliverables: []}) { taskState decisionKind } }",
        .object(["reportAttempt": .object(["taskState": .string("succeeded"), "decisionKind": .string("complete")])])
      )
    ]
    for (query, expectedData) in docs {
      let response = await executor.execute(GraphQLDocumentRequest(query: query, isLocallyTrusted: true))
      XCTAssertTrue(response.handled, query)
      XCTAssertNil(response.body["errors"], query)
      XCTAssertEqual(response.body["data"], expectedData, query)
    }
    let recordedCalls = await provider.recordedCalls()
    XCTAssertEqual(recordedCalls, [
      "taskHandover:t-1:h-1",
      "tasksAwaitingHandover:userReachable",
      "requestTaskHandover:t-1:move:true",
      "answerTask:t-1:q-1:string(\"yes\")",
      "takeoverTask:t-1:h-1:host:userReachable",
      "heartbeatAttempt:a-2:token",
      "reportAttempt:a-2:token:0"
    ])
  }

  func testUnrelatedDocumentDelegatesToNext() async {
    let unrelated = "{ routines { routines { routineId } } }"
    let next = RecordingNextExecutor(response: .notHandled)
    let executor = TaskHandoverGraphQLDocumentExecutor(provider: StubTaskHandoverProvider(), next: next)
    let response = await executor.execute(GraphQLDocumentRequest(query: unrelated))
    XCTAssertFalse(response.handled)
    XCTAssertEqual(next.queries, [unrelated])

    let passthrough = GraphQLDocumentExecutionResponse(handled: true, body: ["data": .object(["routines": .null])])
    let handlingNext = RecordingNextExecutor(response: passthrough)
    let delegating = TaskHandoverGraphQLDocumentExecutor(provider: StubTaskHandoverProvider(), next: handlingNext)
    let delegated = await delegating.execute(GraphQLDocumentRequest(query: unrelated))
    XCTAssertEqual(delegated, passthrough)
    XCTAssertEqual(handlingNext.queries, [unrelated])
  }

  func testProviderNotFoundBecomesPayloadError() async {
    let provider = StubTaskHandoverProvider(failure: TaskHandoverGraphQLError(code: "not_found", message: "missing"))
    let executor = TaskHandoverGraphQLDocumentExecutor(provider: provider)
    let response = await executor.execute(GraphQLDocumentRequest(
      query: "{ taskHandover(taskId: \"missing\") { errors { code message } } }",
      isLocallyTrusted: true
    ))
    guard case let .object(data)? = response.body["data"],
          case let .object(payload)? = data["taskHandover"],
          case let .array(errors)? = payload["errors"],
          case let .object(error)? = errors.first
    else { return XCTFail("unexpected response: \(response.body)") }
    XCTAssertEqual(error["code"], .string("not_found"))
    XCTAssertEqual(error["message"], .string("missing"))
  }

  func testOversizedReportIsRejectedBeforeProviderCall() async throws {
    let provider = StubTaskHandoverProvider()
    let executor = TaskHandoverGraphQLDocumentExecutor(provider: provider)
    let input: JSONObject = [
      "attemptId": .string("a-2"), "token": .string("token"),
      "snapshot": .object(["blob": .string(String(repeating: "x", count: 5 * 1024 * 1024))]),
      "deliverables": .array([])
    ]
    let response = await executor.execute(GraphQLDocumentRequest(
      query: "mutation($input: JSONObject!) { reportAttempt(input: $input) { errors { code } } }",
      variables: ["input": .object(input)],
      isLocallyTrusted: true
    ))
    guard case let .object(data)? = response.body["data"],
          case let .object(payload)? = data["reportAttempt"],
          case let .array(errors)? = payload["errors"],
          case let .object(error)? = errors.first
    else { return XCTFail("unexpected response: \(response.body)") }
    XCTAssertEqual(error["code"], .string("invalid_input"))
    let recordedCalls = await provider.recordedCalls()
    XCTAssertTrue(recordedCalls.isEmpty)
  }

  func testSchemaBlockContainsPinnedTypesAndInputs() {
    for name in [
      "HandoverPacket", "TaskHandoverSummary", "RequestTaskHandoverInput", "AnswerTaskInput",
      "TakeoverTaskInput", "TakeoverTaskPayload", "LeaseStatePayload", "ReportAttemptInput",
      "ReportAttemptPayload", "TaskHandoverMutationPayload"
    ] {
      XCTAssertTrue(taskHandoverGraphQLSchemaTypes.contains(name), "missing \(name)")
    }
  }

  func testPreflightDelegatesNonTaskRootsForUntrustedRequests() async throws {
    let next = PreflightingNextExecutor()
    let executor = TaskHandoverGraphQLDocumentExecutor(provider: StubTaskHandoverProvider(), next: next)
    let request = GraphQLDocumentRequest(query: "mutation { stopSession(input: {sessionId: \"s\"}) { sessionId } }", isLocallyTrusted: false)
    let roots = try parsedRoots(request.query)
    let result = await executor.preflight(request, rootFields: roots)
    XCTAssertNil(result)
    XCTAssertEqual(next.preflightedRoots, [["stopSession"]])
  }

  func testPreflightDelegatesOnlyNonTaskRootsOfMixedDocumentAndPropagatesRejection() async throws {
    let rejection = handoverTestRejection(code: "downstream_rejected")
    let next = PreflightingNextExecutor(rejection: rejection)
    let executor = TaskHandoverGraphQLDocumentExecutor(provider: StubTaskHandoverProvider(), next: next)
    let request = GraphQLDocumentRequest(
      query: "mutation { heartbeatAttempt(attemptId: \"a\", token: \"t\") { fenced } otherField { x } }",
      isLocallyTrusted: true
    )
    let result = await executor.preflight(request, rootFields: try parsedRoots(request.query))
    XCTAssertEqual(result, rejection)
    XCTAssertEqual(next.preflightedRoots, [["otherField"]])
  }

  func testPreflightRejectsUntrustedTaskRootWithoutConsultingNext() async throws {
    let next = PreflightingNextExecutor()
    let executor = TaskHandoverGraphQLDocumentExecutor(provider: StubTaskHandoverProvider(), next: next)
    let request = GraphQLDocumentRequest(
      query: "mutation { heartbeatAttempt(attemptId: \"a\", token: \"t\") { fenced } otherField { x } }",
      isLocallyTrusted: false
    )
    let result = await executor.preflight(request, rootFields: try parsedRoots(request.query))
    XCTAssertEqual(errorCode(result), .string("unauthorized"))
    XCTAssertTrue(next.preflightedRoots.isEmpty)
  }

  func testPreflightRejectsMixedDocumentWhenNextIsMissingOrNotPreflighting() async throws {
    let request = GraphQLDocumentRequest(
      query: "mutation { heartbeatAttempt(attemptId: \"a\", token: \"t\") { fenced } otherField { x } }",
      isLocallyTrusted: true
    )
    let roots = try parsedRoots(request.query)
    let withoutNext = TaskHandoverGraphQLDocumentExecutor(provider: StubTaskHandoverProvider())
    let missing = await withoutNext.preflight(request, rootFields: roots)
    XCTAssertEqual(errorCode(missing), .string("invalid_input"))
    let plainNext = RecordingNextExecutor(response: .notHandled)
    let withPlainNext = TaskHandoverGraphQLDocumentExecutor(provider: StubTaskHandoverProvider(), next: plainNext)
    let plain = await withPlainNext.preflight(request, rootFields: roots)
    XCTAssertEqual(errorCode(plain), .string("invalid_input"))
    XCTAssertTrue(plainNext.queries.isEmpty)
  }

  func testPreflightRejectsTaskQueryFieldInsideMutationOperation() async throws {
    let executor = TaskHandoverGraphQLDocumentExecutor(provider: StubTaskHandoverProvider())
    let request = GraphQLDocumentRequest(query: "mutation { taskHandover(taskId: \"t\") { errors { code } } }", isLocallyTrusted: true)
    let result = await executor.preflight(request, rootFields: try parsedRoots(request.query))
    XCTAssertEqual(errorCode(result), .string("invalid_input"))
  }
}
