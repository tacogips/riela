import Foundation
import RielaCore
import XCTest
@testable import RielaGraphQL

final class WorkflowExecutionGraphQLTests: XCTestCase {
  private let mutation = """
  mutation ExecuteWorkflow($input: ExecuteWorkflowInput!) {
    executeWorkflow(input: $input) { workflowExecutionId sessionId status exitCode }
  }
  """
  private let summaryQuery = """
  query WorkflowExecutionSummary($workflowExecutionId: String!) {
    workflowExecution(workflowExecutionId: $workflowExecutionId) {
      session { sessionId workflowName workflowId transitions { when } }
      nodeExecutions { nodeExecId }
    }
  }
  """

  func testAuthenticatedClientMutationAndPersistedSummarySelections() async {
    let provider = RecordingWorkflowExecutionProvider()
    let executor = authorizedExecutor(provider: provider)
    let start = await executor.execute(request(mutation, variables: ["input": .object([
      "workflowName": .string("ordinary"),
      "runtimeVariables": .object(["message": .string("hello")]),
      "maxSteps": .number(4.0)
    ])]))
    XCTAssertEqual(start.status, 200)
    XCTAssertNil(start.body["errors"], "\(start.body)")
    XCTAssertEqual(field("executeWorkflow", in: start)?["workflowExecutionId"], .string("session-1"))
    XCTAssertEqual(field("executeWorkflow", in: start)?["sessionId"], .string("session-1"))
    XCTAssertEqual(field("executeWorkflow", in: start)?["status"], .string("completed"))
    XCTAssertEqual(field("executeWorkflow", in: start)?["exitCode"], .integer(0))
    let inputs = await provider.receivedInputs()
    XCTAssertEqual(inputs.count, 1)
    XCTAssertEqual(inputs.first?.workflowName, "ordinary")
    XCTAssertEqual(inputs.first?.runtimeVariables?["message"], .string("hello"))
    XCTAssertEqual(inputs.first?.maxSteps, 4)

    let summary = await executor.execute(request(summaryQuery, variables: [
      "workflowExecutionId": .string("session-1")
    ]))
    XCTAssertNil(summary.body["errors"], "\(summary.body)")
    guard let payload = field("workflowExecution", in: summary),
          case let .object(session)? = payload["session"],
          case let .array(transitions)? = session["transitions"],
          case let .array(nodes)? = payload["nodeExecutions"] else {
      return XCTFail("missing typed summary: \(summary.body)")
    }
    XCTAssertEqual(session["sessionId"], .string("session-1"))
    XCTAssertEqual(session["workflowName"], .string("ordinary"))
    XCTAssertEqual(session["workflowId"], .string("workflow-1"))
    XCTAssertEqual(transitions, [.object(["when": .string("ready")]), .object(["when": .null])])
    XCTAssertEqual(nodes, [.object(["nodeExecId": .string("node-1")])])
  }

  func testUnknownWellFormedSummaryIsNull() async {
    let provider = RecordingWorkflowExecutionProvider()
    let response = await authorizedExecutor(provider: provider).execute(request(
      summaryQuery,
      variables: ["workflowExecutionId": .string("absent")]
    ))
    XCTAssertNil(response.body["errors"], "\(response.body)")
    guard case let .object(data)? = response.body["data"] else {
      return XCTFail("missing data: \(response.body)")
    }
    XCTAssertEqual(data["workflowExecution"], .null)
  }

  func testForbiddenFieldsRejectEveryValueAndResolvedInputFormBeforeProviderEffects() async {
    let provider = RecordingWorkflowExecutionProvider()
    let executor = authorizedExecutor(provider: provider)
    let values: [JSONValue] = [.bool(true), .bool(false), .null, .integer(0), .object([:])]
    for key in ["autoImprove", "nestedSuperviser"] {
      for value in values {
        let input: JSONObject = ["workflowName": .string("ordinary"), key: value]
        let wholeVariable = await executor.execute(request(mutation, variables: ["input": .object(input)]))
        XCTAssertEqual(errorCode(wholeVariable), "INVALID_EXECUTION_INPUT", "\(key) \(value)")

        let inline = await executor.execute(request(
          "mutation { executeWorkflow(input: {workflowName: \"ordinary\", \(key): \(graphQLLiteral(value))}) "
            + "{ sessionId } }"
        ))
        XCTAssertEqual(errorCode(inline), "INVALID_EXECUTION_INPUT", "\(key) inline \(value)")

        let fieldVariable = await executor.execute(request(
          "mutation Test($extra: JSONObject) { executeWorkflow(input: "
            + "{workflowName: \"ordinary\", \(key): $extra}) { sessionId } }",
          variables: ["extra": value]
        ))
        XCTAssertNotNil(fieldVariable.body["errors"], "\(key) variable \(value)")

        let defaultValue = await executor.execute(request(
          "mutation Test($input: ExecuteWorkflowInput! = {workflowName: \"ordinary\", "
            + "\(key): \(graphQLLiteral(value))}) { executeWorkflow(input: $input) { sessionId } }"
        ))
        XCTAssertEqual(errorCode(defaultValue), "INVALID_EXECUTION_INPUT", "\(key) default \(value)")
      }
    }
    let both = await executor.execute(request(mutation, variables: ["input": .object([
      "workflowName": .string("ordinary"), "autoImprove": .null, "nestedSuperviser": .bool(false)
    ])]))
    XCTAssertEqual(errorCode(both), "INVALID_EXECUTION_INPUT")
    let calls = await provider.receivedInputs()
    XCTAssertTrue(calls.isEmpty)
  }

  func testOpaqueRuntimeVariablesMayContainHistoricalNames() async {
    let provider = RecordingWorkflowExecutionProvider()
    let response = await authorizedExecutor(provider: provider).execute(request(mutation, variables: [
      "input": .object([
        "workflowName": .string("ordinary"),
        "runtimeVariables": .object(["autoImprove": .bool(false), "nestedSuperviser": .null])
      ])
    ]))
    XCTAssertNil(response.body["errors"], "\(response.body)")
    let count = await provider.executeCallCount()
    XCTAssertEqual(count, 1)
  }

  func testInputTypeAndBoundFailuresRejectBeforeProviderEffects() async {
    let provider = RecordingWorkflowExecutionProvider()
    let executor = authorizedExecutor(provider: provider)
    let invalidInputs: [JSONObject] = [
      [:], ["workflowName": .string("  ")], ["workflowName": .integer(3)],
      ["workflowName": .string("ordinary"), "instanceIdentity": .string("")],
      ["workflowName": .string("ordinary"), "runtimeVariables": .array([])],
      ["workflowName": .string("ordinary"), "nodePatch": .bool(false)],
      ["workflowName": .string("ordinary"), "disableDefaultLoopGuard": .string("false")],
      ["workflowName": .string("ordinary"), "maxSteps": .integer(0)],
      ["workflowName": .string("ordinary"), "maxSteps": .number(1.5)],
      ["workflowName": .string("ordinary"), "maxConcurrency": .integer(2_147_483_648)],
      ["workflowName": .string("ordinary"), "maxLoopIterations": .bool(true)],
      ["workflowName": .string("ordinary"), "defaultTimeoutMs": .string("10")],
      ["workflowName": .string("ordinary"), "timeoutMs": .integer(10)],
      ["workflowName": .string("ordinary"), "credential": .string("fake")],
      ["workflowName": .string("ordinary"), "scope": .string("USER")]
    ]
    for input in invalidInputs {
      let response = await executor.execute(request(mutation, variables: ["input": .object(input)]))
      XCTAssertEqual(errorCode(response), "INVALID_EXECUTION_INPUT", "\(input): \(response.body)")
    }
    let unknownArgument = await executor.execute(request(
      "mutation { executeWorkflow(input: {workflowName: \"ordinary\"}, unknown: 1) { sessionId } }"
    ))
    XCTAssertEqual(errorCode(unknownArgument), "INVALID_EXECUTION_INPUT")
    let count = await provider.executeCallCount()
    XCTAssertEqual(count, 0)
  }

  func testMissingWrongOrUnconfiguredBearerRejectsReadAndStartBeforeProviderEffects() async {
    let provider = RecordingWorkflowExecutionProvider()
    let documentRequests = [
      request(mutation, variables: ["input": .object(["workflowName": .string("ordinary")])]),
      request(summaryQuery, variables: ["workflowExecutionId": .string("session-1")])
    ]
    for document in documentRequests {
      var noBearer = document
      noBearer.transportCredential = nil
      var wrongBearer = document
      wrongBearer.transportCredential = GraphQLTransportCredential("wrong-secret")
      var spoofedClient = noBearer
      spoofedClient.authenticatedClientId = "operator"
      for invalid in [noBearer, wrongBearer, spoofedClient] {
        let response = await authorizedExecutor(provider: provider).execute(invalid)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.body["data"], .null)
        XCTAssertEqual(errorCode(response), "UNAUTHENTICATED")
        XCTAssertFalse(String(describing: response.body).contains("correct-secret"))
        XCTAssertFalse(String(describing: response.body).contains("wrong-secret"))
      }
      let unconfigured = WorkflowExecutionAuthorizationWrapper(
        expectedBearer: nil,
        next: WorkflowExecutionGraphQLDocumentExecutor(provider: provider)
      )
      let unconfiguredResponse = await unconfigured.execute(document)
      XCTAssertEqual(errorCode(unconfiguredResponse), "UNAUTHENTICATED")
    }
    let executeCount = await provider.executeCallCount()
    let summaryCount = await provider.summaryCallCount()
    XCTAssertEqual(executeCount, 0)
    XCTAssertEqual(summaryCount, 0)
  }

  func testOperationSelectionAndInvalidSelectionsFailBeforeEffects() async {
    let provider = RecordingWorkflowExecutionProvider()
    let executor = authorizedExecutor(provider: provider)
    let documents = [
      "query { executeWorkflow(input: {workflowName: \"ordinary\"}) { sessionId } }",
      "mutation { workflowExecution(workflowExecutionId: \"session-1\") { session { sessionId } } }",
      "mutation { executeWorkflow(input: {workflowName: \"ordinary\"}) { unknownField } }",
      "mutation { executeWorkflow(input: {workflowName: \"ordinary\"}) { sessionId { impossible } } }",
      "mutation { one: executeWorkflow(input: {workflowName: \"ordinary\"}) { sessionId } "
        + "one: executeWorkflow(input: {workflowName: \"ordinary\"}) { sessionId } }",
      "mutation { executeWorkflow(input: {workflowName: \"ordinary\"}) { sessionId } "
        + "executeWorkflow(input: {workflowName: \"ordinary\"}) { sessionId } }"
    ]
    for document in documents {
      let response = await executor.execute(request(document))
      XCTAssertNotNil(response.body["errors"], "\(document): \(response.body)")
    }
    let unselectedBad = await executor.execute(request(
      "mutation Good { executeWorkflow(input: {workflowName: \"ordinary\"}) { sessionId } } "
        + "mutation Bad { executeWorkflow(input: {workflowName: \"ordinary\", autoImprove: false}) { sessionId } }",
      operationName: "Good"
    ))
    XCTAssertEqual(errorCode(unselectedBad), "INVALID_EXECUTION_INPUT")
    let executeCount = await provider.executeCallCount()
    let summaryCount = await provider.summaryCallCount()
    XCTAssertEqual(executeCount, 0)
    XCTAssertEqual(summaryCount, 0)
  }

  func testAliasesFragmentsAndSelectedOperationWork() async {
    let provider = RecordingWorkflowExecutionProvider()
    let executor = authorizedExecutor(provider: provider)
    let response = await executor.execute(request(
      "mutation Selected { aliasRun: executeWorkflow(input: {workflowName: \"ordinary\"}) "
        + "{ ...RunFields } } fragment RunFields on ExecuteWorkflowPayload { sessionId status } "
        + "mutation Other { executeWorkflow(input: {workflowName: \"ordinary\"}) { sessionId } }",
      operationName: "Selected"
    ))
    XCTAssertNil(response.body["errors"], "\(response.body)")
    XCTAssertEqual(field("aliasRun", in: response), ["sessionId": .string("session-1"), "status": .string("completed")])
    let count = await provider.executeCallCount()
    XCTAssertEqual(count, 1)
  }

  func testSelectedOperationMayReuseResponseKeyFromAnotherOperation() async {
    let provider = RecordingWorkflowExecutionProvider()
    let response = await authorizedExecutor(provider: provider).execute(request(
      "mutation A { executeWorkflow(input: {workflowName: \"ordinary\"}) { sessionId } } "
        + "mutation B { executeWorkflow(input: {workflowName: \"ordinary\"}) { sessionId } }",
      operationName: "A"
    ))
    XCTAssertNil(response.body["errors"], "\(response.body)")
    XCTAssertEqual(field("executeWorkflow", in: response)?["sessionId"], .string("session-1"))
    let count = await provider.executeCallCount()
    XCTAssertEqual(count, 1)
  }

  func testProviderFailureMapsToExecutionError() async {
    let provider = RecordingWorkflowExecutionProvider(shouldFail: true)
    let response = await authorizedExecutor(provider: provider).execute(request(mutation, variables: [
      "input": .object(["workflowName": .string("ordinary")])
    ]))
    XCTAssertEqual(errorCode(response), "WORKFLOW_EXECUTION_FAILED")
    let count = await provider.executeCallCount()
    XCTAssertEqual(count, 1)
  }

  func testCompositeRejectsLaterInvalidExecutionBeforeEarlierDomainMutation() async {
    let provider = RecordingWorkflowExecutionProvider()
    let note = RecordingNoteMutationExecutor()
    let composite = CompositeGraphQLDocumentExecutor(
      workflowRegistry: WorkflowRegistryGraphQLDocumentExecutor(localProvider: StubWorkflowRegistryProvider()),
      fallback: WorkflowExecutionGraphQLDocumentExecutor(provider: provider, next: note)
    )
    let executor = WorkflowExecutionAuthorizationWrapper(expectedBearer: "correct-secret", next: composite)
    let response = await executor.execute(request(
      "mutation { noteDelete(id: \"note-1\") { accepted } "
        + "executeWorkflow(input: {workflowName: \"ordinary\", autoImprove: false}) { sessionId } }"
    ))
    XCTAssertEqual(errorCode(response), "INVALID_EXECUTION_INPUT")
    let noteCalls = await note.callCount()
    let executionCalls = await provider.executeCallCount()
    XCTAssertEqual(noteCalls, 0)
    XCTAssertEqual(executionCalls, 0)
  }

  func testExecutionBearerDoesNotGrantRegistryMutationCapability() async {
    let provider = RecordingWorkflowExecutionProvider()
    let registry = WorkflowRegistryGraphQLDocumentExecutor(configuration: WorkflowRegistryGraphQLServerConfig(
      provider: StubWorkflowRegistryProvider(),
      authorizer: StubWorkflowRegistryAuthorizer(capabilities: []),
      managedReferenceResolver: StubManagedReferenceResolver()
    ))
    let executor = WorkflowExecutionAuthorizationWrapper(
      expectedBearer: "correct-secret",
      next: CompositeGraphQLDocumentExecutor(
        workflowRegistry: registry,
        fallback: WorkflowExecutionGraphQLDocumentExecutor(provider: provider)
      )
    )
    let response = await executor.execute(request(
      "mutation { deleteMutableWorkflow(input: {target: {workflowId: \"alpha\"}}) { accepted } "
        + "executeWorkflow(input: {workflowName: \"ordinary\"}) { sessionId } }"
    ))
    XCTAssertEqual(errorCode(response), WorkflowRegistryErrorCode.forbidden.rawValue)
    let executionCalls = await provider.executeCallCount()
    XCTAssertEqual(executionCalls, 0)
  }

  func testLocalTrustCanExecuteWithoutBearerButEmptyConfiguredBearerCannot() async {
    let provider = RecordingWorkflowExecutionProvider()
    let executor = WorkflowExecutionAuthorizationWrapper(
      expectedBearer: nil,
      next: WorkflowExecutionGraphQLDocumentExecutor(provider: provider)
    )
    var localRequest = request(mutation, variables: [
      "input": .object(["workflowName": .string("ordinary")])
    ])
    localRequest.transportCredential = nil
    localRequest.isLocallyTrusted = true
    let localResponse = await executor.execute(localRequest)
    XCTAssertNil(localResponse.body["errors"], "\(localResponse.body)")
    let localCount = await provider.executeCallCount()
    XCTAssertEqual(localCount, 1)

    let remoteResponse = await WorkflowExecutionAuthorizationWrapper(
      expectedBearer: "",
      next: WorkflowExecutionGraphQLDocumentExecutor(provider: provider)
    ).execute(request(mutation, variables: [
      "input": .object(["workflowName": .string("ordinary")])
    ]))
    XCTAssertEqual(errorCode(remoteResponse), "UNAUTHENTICATED")
    let finalCount = await provider.executeCallCount()
    XCTAssertEqual(finalCount, 1)
  }

  private func authorizedExecutor(provider: RecordingWorkflowExecutionProvider) -> WorkflowExecutionAuthorizationWrapper {
    WorkflowExecutionAuthorizationWrapper(
      expectedBearer: "correct-secret",
      next: WorkflowExecutionGraphQLDocumentExecutor(provider: provider)
    )
  }

  private func request(
    _ query: String,
    variables: JSONObject = [:],
    operationName: String? = nil
  ) -> GraphQLDocumentRequest {
    GraphQLDocumentRequest(
      query: query,
      variables: variables,
      operationName: operationName,
      transportCredential: GraphQLTransportCredential("correct-secret")
    )
  }

  private func field(_ name: String, in response: GraphQLDocumentExecutionResponse) -> JSONObject? {
    guard case let .object(data)? = response.body["data"],
          case let .object(value)? = data[name] else { return nil }
    return value
  }

  private func errorCode(_ response: GraphQLDocumentExecutionResponse) -> String? {
    guard case let .array(errors)? = response.body["errors"],
          case let .object(error)? = errors.first,
          case let .object(extensions)? = error["extensions"],
          case let .string(code)? = extensions["code"] else { return nil }
    return code
  }

  private func graphQLLiteral(_ value: JSONValue) -> String {
    switch value {
    case let .bool(value): return value ? "true" : "false"
    case .null: return "null"
    case let .integer(value): return String(value)
    case .object: return "{}"
    default: return "null"
    }
  }
}

private enum TestWorkflowExecutionFailure: Error {
  case failed
}

private actor RecordingWorkflowExecutionProvider: WorkflowExecutionGraphQLProviding {
  private var inputs: [GraphQLExecuteWorkflowInput] = []
  private var summaryIDs: [String] = []
  private let shouldFail: Bool

  init(shouldFail: Bool = false) {
    self.shouldFail = shouldFail
  }

  func executeWorkflow(_ input: GraphQLExecuteWorkflowInput) async throws -> GraphQLExecuteWorkflowPayload {
    inputs.append(input)
    if shouldFail { throw TestWorkflowExecutionFailure.failed }
    return GraphQLExecuteWorkflowPayload(
      workflowExecutionId: "session-1",
      sessionId: "session-1",
      status: "completed",
      exitCode: 0
    )
  }

  func workflowExecution(workflowExecutionId: String) async throws -> GraphQLWorkflowExecutionSummary? {
    summaryIDs.append(workflowExecutionId)
    guard workflowExecutionId == "session-1" else { return nil }
    return GraphQLWorkflowExecutionSummary(
      session: GraphQLWorkflowExecutionSessionSummary(
        sessionId: "session-1",
        workflowName: "ordinary",
        workflowId: "workflow-1",
        transitions: [
          GraphQLExecutionTransitionSummary(when: "ready"),
          GraphQLExecutionTransitionSummary(when: nil)
        ]
      ),
      nodeExecutions: [GraphQLWorkflowExecutionNodeSummary(nodeExecId: "node-1")]
    )
  }

  func receivedInputs() -> [GraphQLExecuteWorkflowInput] { inputs }
  func executeCallCount() -> Int { inputs.count }
  func summaryCallCount() -> Int { summaryIDs.count }
}

private actor RecordingNoteMutationExecutor: GraphQLDocumentExecuting, GraphQLDocumentDomainPreflighting {
  private var calls = 0

  func preflight(
    _ request: GraphQLDocumentRequest,
    rootFields: [ParsedGraphQLRootField]
  ) async -> GraphQLDocumentExecutionResponse? {
    guard rootFields.allSatisfy({ $0.fieldName == "noteDelete" && $0.operationType == .mutation }) else {
      return GraphQLDocumentExecutionResponse(handled: true, body: [
        "data": .null,
        "errors": .array([.object(["message": .string("unsupported note mutation")])])
      ])
    }
    return nil
  }

  func execute(_ request: GraphQLDocumentRequest) async -> GraphQLDocumentExecutionResponse {
    calls += 1
    return GraphQLDocumentExecutionResponse(handled: true, body: [
      "data": .object(["noteDelete": .object(["accepted": .bool(true)])])
    ])
  }

  func callCount() -> Int { calls }
}
