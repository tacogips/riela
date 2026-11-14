import Foundation
import RielaCore
import XCTest
@testable import RielaGraphQL

final class GraphQLWorkflowRegistryTests: XCTestCase {
  func testSchemaPublishesAdditiveRegistryContract() {
    let schema = GraphQLContractProjector.schemaContract
    for token in [
      "workflows(filter: WorkflowFilter)",
      "workflow(target: WorkflowTargetInput!)",
      "registerMutableWorkflow",
      "updateMutableWorkflow",
      "deleteMutableWorkflow",
      "activateWorkflow",
      "deactivateWorkflow",
      "consolidateWorkflows",
      "IMMUTABLE_WORKFLOW",
      "WORKFLOW_DEACTIVATED"
    ] {
      XCTAssertTrue(schema.contains(token), token)
    }
    XCTAssertTrue(schema.contains("workflowSession(workflowId:"), "existing query must remain additive")
  }

  func testLocalTrustedExecutorListsAndFiltersRegistryEntries() async throws {
    let executor = WorkflowRegistryGraphQLDocumentExecutor(localProvider: StubWorkflowRegistryProvider())
    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      query RegistryList($filter: WorkflowFilter) {
        workflows(filter: $filter) {
          workflows { workflowId name provenance mutable activationState description }
          errors { code message }
        }
      }
      """,
      variables: ["filter": .object(["query": .string("alpha")])],
      operationName: "RegistryList",
      isLocallyTrusted: true
    ))
    XCTAssertTrue(response.handled)
    guard case let .object(data)? = response.body["data"],
          case let .object(payload)? = data["workflows"],
          case let .array(workflows)? = payload["workflows"] else {
      return XCTFail("missing workflows payload: \(response.body)")
    }
    XCTAssertEqual(workflows.count, 1)
    guard case let .object(entry) = workflows[0] else { return XCTFail("missing entry") }
    XCTAssertEqual(entry["workflowId"], .string("alpha"))
    XCTAssertEqual(entry["provenance"], .string("MUTABLE"))
  }

  func testRemoteRegistryDefaultsUnavailableBeforeDispatch() async {
    let executor = WorkflowRegistryGraphQLDocumentExecutor()
    let response = await executor.execute(GraphQLDocumentRequest(
      query: "query { workflows { workflows { workflowId } errors { code } } }"
    ))
    XCTAssertTrue(response.handled)
    XCTAssertEqual(errorCode(response), WorkflowRegistryErrorCode.workflowRegistryUnavailable.rawValue)
  }

  func testRemoteAuthorizationSeparatesReadAndMutationCapabilities() async {
    let provider = StubWorkflowRegistryProvider()
    let configuration = WorkflowRegistryGraphQLServerConfig(
      provider: provider,
      authorizer: StubWorkflowRegistryAuthorizer(capabilities: [.readRegistry]),
      managedReferenceResolver: StubManagedReferenceResolver()
    )
    let executor = WorkflowRegistryGraphQLDocumentExecutor(configuration: configuration)
    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation {
        deleteMutableWorkflow(input: {target: {workflowId: "alpha"}}) {
          accepted
          errors { code }
        }
      }
      """,
      transportCredential: GraphQLTransportCredential("secret")
    ))
    XCTAssertEqual(errorCode(response), WorkflowRegistryErrorCode.forbidden.rawValue)
    XCTAssertFalse(String(describing: response.body).contains("secret"))
  }

  func testImmutableMutationReturnsTypedPayloadError() async {
    let executor = WorkflowRegistryGraphQLDocumentExecutor(localProvider: StubWorkflowRegistryProvider())
    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation {
        deleteMutableWorkflow(input: {target: {workflowId: "immutable"}}) {
          accepted
          errors { code message workflowId }
        }
      }
      """,
      isLocallyTrusted: true
    ))
    guard case let .object(data)? = response.body["data"],
          case let .object(payload)? = data["deleteMutableWorkflow"],
          case let .array(errors)? = payload["errors"],
          case let .object(error) = errors[0] else {
      return XCTFail("missing typed mutation error: \(response.body)")
    }
    XCTAssertEqual(payload["accepted"], .bool(false))
    XCTAssertEqual(error["code"], .string(WorkflowRegistryErrorCode.immutableWorkflow.rawValue))
  }

  func testDefinitionUpdateRequiresRevisionBeforeProviderDispatch() async {
    let executor = WorkflowRegistryGraphQLDocumentExecutor(localProvider: StubWorkflowRegistryProvider())
    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation Update($input: UpdateMutableWorkflowInput!) {
        updateMutableWorkflow(input: $input) { accepted errors { code message } }
      }
      """,
      variables: [
        "input": .object([
          "target": .object(["workflowId": .string("alpha")]),
          "definition": .object(["workflowId": .string("alpha")])
        ])
      ],
      operationName: "Update",
      isLocallyTrusted: true
    ))
    XCTAssertEqual(errorCode(response), WorkflowRegistryErrorCode.invalidWorkflow.rawValue)
  }

  func testBundleUpdateRejectsDefinitionRevisionBeforeProviderDispatch() async {
    let executor = WorkflowRegistryGraphQLDocumentExecutor(localProvider: StubWorkflowRegistryProvider())
    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation Update($input: UpdateMutableWorkflowInput!) {
        updateMutableWorkflow(input: $input) { accepted errors { code message } }
      }
      """,
      variables: [
        "input": .object([
          "target": .object(["workflowId": .string("alpha")]),
          "bundle": .object([
            "kind": .string("PATH"),
            "value": .string("/tmp/unused")
          ]),
          "expectedDefinitionRevision": .string("unexpected")
        ])
      ],
      operationName: "Update",
      isLocallyTrusted: true
    ))
    XCTAssertEqual(errorCode(response), WorkflowRegistryErrorCode.invalidWorkflow.rawValue)
  }

  func testCompositeExecutorPreflightsAndExecutesMixedDomainDocument() async {
    let executor = CompositeGraphQLDocumentExecutor(
      workflowRegistry: WorkflowRegistryGraphQLDocumentExecutor(localProvider: StubWorkflowRegistryProvider()),
      fallback: StubNoteDocumentExecutor()
    )
    let response = await executor.execute(GraphQLDocumentRequest(
      query: "query { workflows { workflows { workflowId } } note(id: \"note-1\") { id } }",
      isLocallyTrusted: true
    ))
    guard case let .object(data)? = response.body["data"] else {
      return XCTFail("missing mixed-domain data: \(response.body)")
    }
    XCTAssertNotNil(data["workflows"])
    XCTAssertEqual(data["note"], .object(["id": .string("note-1")]))
  }

  func testCompositeExecutorCompletesAllDomainPreflightBeforeMutationDispatch() async {
    let provider = RecordingWorkflowRegistryProvider()
    let executor = CompositeGraphQLDocumentExecutor(
      workflowRegistry: WorkflowRegistryGraphQLDocumentExecutor(localProvider: provider),
      fallback: RejectingNoteDocumentExecutor()
    )
    let response = await executor.execute(GraphQLDocumentRequest(
      query: "mutation { deleteMutableWorkflow(input: {target: {workflowId: \"alpha\"}}) "
        + "{ accepted } noteDelete(id: \"note-1\") { accepted } }",
      isLocallyTrusted: true
    ))
    XCTAssertEqual(errorCode(response), WorkflowRegistryErrorCode.forbidden.rawValue)
    let deleteCalls = await provider.deleteCallCount()
    XCTAssertEqual(deleteCalls, 0)
  }

  func testCompositeExecutorDoesNotPropagateRawCredentialAfterPreflight() async {
    let fallback = CredentialRecordingNoteExecutor()
    let registry = WorkflowRegistryGraphQLDocumentExecutor(configuration: WorkflowRegistryGraphQLServerConfig(
      provider: StubWorkflowRegistryProvider(),
      authorizer: StubWorkflowRegistryAuthorizer(capabilities: [.readRegistry]),
      managedReferenceResolver: StubManagedReferenceResolver()
    ))
    let response = await CompositeGraphQLDocumentExecutor(
      workflowRegistry: registry,
      fallback: fallback
    ).execute(GraphQLDocumentRequest(
      query: "query { workflows { workflows { workflowId } } note(id: \"note-1\") { id } }",
      transportCredential: GraphQLTransportCredential("raw-secret")
    ))
    XCTAssertTrue(response.handled)
    let observedCredential = await fallback.observedCredential()
    let observedPreflightCredential = await fallback.observedPreflightCredential()
    XCTAssertNil(observedCredential)
    XCTAssertNil(observedPreflightCredential)
    XCTAssertFalse(String(describing: response.body).contains("raw-secret"))
  }

  func testInvalidRegistrySelectionCannotDispatchDestructiveMutation() async {
    let provider = RecordingWorkflowRegistryProvider()
    let executor = WorkflowRegistryGraphQLDocumentExecutor(localProvider: provider)
    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation {
        deleteMutableWorkflow(input: {target: {workflowId: "alpha"}}) {
          acceptd
        }
      }
      """,
      isLocallyTrusted: true
    ))
    XCTAssertEqual(errorCode(response), WorkflowRegistryErrorCode.invalidWorkflow.rawValue)
    let deleteCalls = await provider.deleteCallCount()
    XCTAssertEqual(deleteCalls, 0)
  }

  func testNestedArgumentsAndDuplicateInputsCannotDispatchDestructiveMutation() async {
    let provider = RecordingWorkflowRegistryProvider()
    let executor = WorkflowRegistryGraphQLDocumentExecutor(localProvider: provider)
    let invalidDocuments = [
      """
      mutation {
        deleteMutableWorkflow(input: {target: {workflowId: "alpha"}}) {
          accepted(unexpected: true)
        }
      }
      """,
      """
      mutation {
        deleteMutableWorkflow(
          input: {target: {workflowId: "alpha"}},
          input: {target: {workflowId: "beta"}}
        ) { accepted }
      }
      """,
      """
      mutation {
        deleteMutableWorkflow(input: {
          target: {workflowId: "alpha", workflowId: "beta"}
        }) { accepted }
      }
      """,
      """
      mutation {
        ...DeleteFields
      }
      fragment DeleteFields on Mutation @skip(if: true) {
        deleteMutableWorkflow(input: {target: {workflowId: "alpha"}}) {
          accepted
        }
      }
      """,
      """
      mutation Delete(
        $id: String! = "alpha",
        $id: String! = "beta"
      ) {
        deleteMutableWorkflow(input: {target: {workflowId: $id}}) {
          accepted
        }
      }
      """,
      """
      mutation Delete($id: = "alpha") {
        deleteMutableWorkflow(input: {target: {workflowId: $id}}) {
          accepted
        }
      }
      """,
      """
      mutation {
        deleteMutableWorkflow(input: {
          "target": {"workflowId": "alpha"}
        }) { accepted }
      }
      """,
      """
      mutation {
        deleteMutableWorkflow(input: {target: {workflowId: "alpha"}}) {
          accepted
        }
      }
      garbage
      """
    ]
    for document in invalidDocuments {
      let response = await executor.execute(GraphQLDocumentRequest(
        query: document,
        isLocallyTrusted: true
      ))
      XCTAssertEqual(errorCode(response), WorkflowRegistryErrorCode.invalidWorkflow.rawValue)
    }
    let deleteCalls = await provider.deleteCallCount()
    XCTAssertEqual(deleteCalls, 0)
  }

  func testInvalidOperationDefinitionsCannotDispatchDestructiveMutation() async {
    let provider = RecordingWorkflowRegistryProvider()
    let executor = WorkflowRegistryGraphQLDocumentExecutor(localProvider: provider)
    let documents = [
      """
      mutation Delete {
        deleteMutableWorkflow(input: {target: {workflowId: "alpha"}}) { accepted }
      }
      mutation Delete {
        deleteMutableWorkflow(input: {target: {workflowId: "beta"}}) { accepted }
      }
      """,
      """
      query {
        workflows { workflows { workflowId } }
      }
      mutation Delete {
        deleteMutableWorkflow(input: {target: {workflowId: "alpha"}}) { accepted }
      }
      """,
      """
      mutation Delete unexpected {
        deleteMutableWorkflow(input: {target: {workflowId: "alpha"}}) { accepted }
      }
      """,
      """
      query Bad {
        workflows(filter: {scope: BOGUS}) { workflows { workflowId } }
      }
      mutation Delete {
        deleteMutableWorkflow(input: {target: {workflowId: "alpha"}}) { accepted }
      }
      """
    ]
    for document in documents {
      let response = await executor.execute(GraphQLDocumentRequest(
        query: document,
        operationName: "Delete",
        isLocallyTrusted: true
      ))
      XCTAssertEqual(errorCode(response), WorkflowRegistryErrorCode.invalidWorkflow.rawValue)
    }
    let deleteCalls = await provider.deleteCallCount()
    XCTAssertEqual(deleteCalls, 0)
  }

  func testCompositePreflightsUnselectedOperationsBeforeDestructiveDispatch() async {
    let provider = RecordingWorkflowRegistryProvider()
    let executor = CompositeGraphQLDocumentExecutor(
      workflowRegistry: WorkflowRegistryGraphQLDocumentExecutor(localProvider: provider),
      fallback: StubNoteDocumentExecutor()
    )
    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      query Bad {
        workflows(filter: {scope: BOGUS}) { workflows { workflowId } }
      }
      mutation Delete {
        deleteMutableWorkflow(input: {target: {workflowId: "alpha"}}) { accepted }
      }
      """,
      operationName: "Delete",
      isLocallyTrusted: true
    ))
    XCTAssertEqual(errorCode(response), WorkflowRegistryErrorCode.invalidWorkflow.rawValue)
    let deleteCalls = await provider.deleteCallCount()
    XCTAssertEqual(deleteCalls, 0)
  }


  func testUnselectedOperationVariablesDoNotRequireRuntimeValues() async {
    let provider = RecordingWorkflowRegistryProvider()
    let executor = CompositeGraphQLDocumentExecutor(
      workflowRegistry: WorkflowRegistryGraphQLDocumentExecutor(localProvider: provider),
      fallback: StubNoteDocumentExecutor()
    )
    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      query Other($scope: WorkflowRegistryScope!) {
        workflows(filter: {scope: $scope}) { workflows { workflowId } }
      }
      mutation Delete($scope: String!) {
        deleteMutableWorkflow(input: {target: {workflowId: $scope}}) { accepted }
      }
      """,
      variables: ["scope": .string("alpha")],
      operationName: "Delete",
      isLocallyTrusted: true
    ))
    XCTAssertNil(response.body["errors"], "\(response.body)")
    let deleteCalls = await provider.deleteCallCount()
    XCTAssertEqual(deleteCalls, 1)
  }

  func testInvalidVariableSchemasCannotDispatchDestructiveMutation() async {
    let provider = RecordingWorkflowRegistryProvider()
    let executor = WorkflowRegistryGraphQLDocumentExecutor(localProvider: provider)
    let invalidRequests = [
      GraphQLDocumentRequest(
        query: """
        query Bad($scope: String!) {
          workflows(filter: {scope: $scope}) { workflows { workflowId } }
        }
        mutation Delete {
          deleteMutableWorkflow(input: {target: {workflowId: "alpha"}}) { accepted }
        }
        """,
        operationName: "Delete",
        isLocallyTrusted: true
      ),
      GraphQLDocumentRequest(
        query: """
        mutation Delete($scope: String!) {
          deleteMutableWorkflow(input: {
            target: {workflowId: "alpha", scope: $scope}
          }) { accepted }
        }
        """,
        variables: ["scope": .string("USER")],
        operationName: "Delete",
        isLocallyTrusted: true
      ),
      GraphQLDocumentRequest(
        query: """
        mutation Delete {
          deleteMutableWorkflow(input: {
            target: {workflowId: $id}
          }) { accepted }
        }
        """,
        variables: ["id": .string("alpha")],
        operationName: "Delete",
        isLocallyTrusted: true
      ),
      GraphQLDocumentRequest(
        query: """
        mutation Delete($id: MissingWorkflowId!) {
          deleteMutableWorkflow(input: {
            target: {workflowId: $id}
          }) { accepted }
        }
        """,
        variables: ["id": .string("alpha")],
        operationName: "Delete",
        isLocallyTrusted: true
      ),
      GraphQLDocumentRequest(
        query: """
        mutation Delete($unused: String) {
          deleteMutableWorkflow(input: {
            target: {workflowId: "alpha"}
          }) { accepted }
        }
        """,
        operationName: "Delete",
        isLocallyTrusted: true
      ),
      GraphQLDocumentRequest(
        query: """
        mutation Delete($scope: WorkflowRegistryScope! = "USER") {
          deleteMutableWorkflow(input: {
            target: {workflowId: "alpha", scope: $scope}
          }) { accepted }
        }
        """,
        operationName: "Delete",
        isLocallyTrusted: true
      )
    ]
    for request in invalidRequests {
      let response = await executor.execute(request)
      XCTAssertEqual(errorCode(response), WorkflowRegistryErrorCode.invalidWorkflow.rawValue)
    }
    let deleteCalls = await provider.deleteCallCount()
    XCTAssertEqual(deleteCalls, 0)
  }

  func testUnusedFragmentDefinitionsCannotDispatchDestructiveMutation() async {
    let provider = RecordingWorkflowRegistryProvider()
    let executor = WorkflowRegistryGraphQLDocumentExecutor(localProvider: provider)
    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation Delete {
        deleteMutableWorkflow(input: {target: {workflowId: "alpha"}}) { accepted }
      }
      fragment Bad on Query {
        workflows(filter: {scope: BOGUS}) { workflows { workflowId } }
      }
      """,
      operationName: "Delete",
      isLocallyTrusted: true
    ))
    XCTAssertEqual(errorCode(response), WorkflowRegistryErrorCode.invalidWorkflow.rawValue)
    let deleteCalls = await provider.deleteCallCount()
    XCTAssertEqual(deleteCalls, 0)
  }

  func testFragmentExpansionLimitsCannotDispatch() async {
    let provider = RecordingWorkflowRegistryProvider()
    let executor = WorkflowRegistryGraphQLDocumentExecutor(localProvider: provider)
    let maximumDepth = GraphQLDocumentLimits.maximumFragmentExpansionDepth
    let chain = (0..<maximumDepth)
      .map { "fragment F\($0) on Query { ...F\($0 + 1) }" }
      .joined(separator: "\n")
    let deepQuery = """
    query { ...F0 }
    \(chain)
    fragment F\(maximumDepth) on Query {
      workflows {
        workflows { workflowId }
        errors { code }
      }
    }
    """
    let branchingDepth = 11
    let branches = (0..<branchingDepth)
      .map { "fragment B\($0) on Query { ...B\($0 + 1) ...B\($0 + 1) }" }
      .joined(separator: "\n")
    let branchingQuery = """
    query { ...B0 }
    \(branches)
    fragment B\(branchingDepth) on Query {
      workflows {
        workflows { workflowId }
        errors { code }
      }
    }
    """
    for query in [deepQuery, branchingQuery] {
      let response = await executor.execute(GraphQLDocumentRequest(
        query: query,
        isLocallyTrusted: true
      ))
      XCTAssertEqual(errorCode(response), WorkflowRegistryErrorCode.invalidWorkflow.rawValue)
    }
    let listCalls = await provider.listCallCount()
    XCTAssertEqual(listCalls, 0)
  }

  func testIncompatibleNestedFragmentTypeCannotDispatch() async {
    let provider = RecordingWorkflowRegistryProvider()
    let executor = WorkflowRegistryGraphQLDocumentExecutor(localProvider: provider)
    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      query {
        workflows {
          workflows { ...WrongType }
          errors { code }
        }
      }
      fragment WrongType on WorkflowMutationPayload {
        workflowId
      }
      """,
      isLocallyTrusted: true
    ))
    XCTAssertEqual(errorCode(response), WorkflowRegistryErrorCode.invalidWorkflow.rawValue)
    let listCalls = await provider.listCallCount()
    XCTAssertEqual(listCalls, 0)
  }

  func testNamedFragmentsExpandBeforeRegistryValidationAndDispatch() async {
    let provider = RecordingWorkflowRegistryProvider()
    let executor = WorkflowRegistryGraphQLDocumentExecutor(localProvider: provider)
    let queryResponse = await executor.execute(GraphQLDocumentRequest(
      query: """
      query Registry {
        ...RegistryFields
      }
      fragment RegistryFields on Query {
        workflows {
          workflows { ...WorkflowFields }
          errors { code }
        }
      }
      fragment WorkflowFields on WorkflowRegistryEntry {
        workflowId
      }
      """,
      operationName: "Registry",
      isLocallyTrusted: true
    ))
    XCTAssertNil(queryResponse.body["errors"], "\(queryResponse.body)")
    let listCalls = await provider.listCallCount()
    XCTAssertEqual(listCalls, 1)

    let mutationResponse = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation Delete {
        deleteMutableWorkflow(input: {target: {workflowId: "alpha"}}) {
          ...MutationFields
        }
      }
      fragment MutationFields on WorkflowMutationPayload {
        accepted
        errors { code }
      }
      """,
      operationName: "Delete",
      isLocallyTrusted: true
    ))
    XCTAssertNil(mutationResponse.body["errors"], "\(mutationResponse.body)")
    let deleteCalls = await provider.deleteCallCount()
    XCTAssertEqual(deleteCalls, 1)
  }

  func testInvalidClosedEnumsAreRejectedBeforeProviderDispatch() async {
    let provider = RecordingWorkflowRegistryProvider()
    let executor = WorkflowRegistryGraphQLDocumentExecutor(localProvider: provider)
    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      query {
        workflows(filter: {scope: BOGUS, provenance: WRONG}) {
          workflows { workflowId }
          errors { code }
        }
      }
      """,
      isLocallyTrusted: true
    ))
    XCTAssertEqual(errorCode(response), WorkflowRegistryErrorCode.invalidWorkflow.rawValue)
    let listCalls = await provider.listCallCount()
    XCTAssertEqual(listCalls, 0)
  }

  func testDuplicateMixedDomainResponseKeyFailsBeforeDispatch() async {
    let provider = RecordingWorkflowRegistryProvider()
    let executor = CompositeGraphQLDocumentExecutor(
      workflowRegistry: WorkflowRegistryGraphQLDocumentExecutor(localProvider: provider),
      fallback: StubNoteDocumentExecutor()
    )
    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation {
        result: deleteMutableWorkflow(input: {target: {workflowId: "alpha"}}) { accepted }
        result: noteDelete(id: "note-1") { accepted }
      }
      """,
      isLocallyTrusted: true
    ))
    XCTAssertEqual(errorCode(response), WorkflowRegistryErrorCode.invalidWorkflow.rawValue)
    let deleteCalls = await provider.deleteCallCount()
    XCTAssertEqual(deleteCalls, 0)
  }

  func testRegistryErrorsRemainLocalToTheirMutationField() async {
    let executor = WorkflowRegistryGraphQLDocumentExecutor(localProvider: StubWorkflowRegistryProvider())
    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation {
        first: deleteMutableWorkflow(input: {target: {workflowId: "alpha"}}) {
          accepted
          errors { code }
        }
        second: deleteMutableWorkflow(input: {target: {workflowId: "immutable"}}) {
          accepted
          errors { code }
        }
      }
      """,
      isLocallyTrusted: true
    ))
    guard case let .object(data)? = response.body["data"],
          case let .object(first)? = data["first"],
          case let .object(second)? = data["second"],
          case let .array(secondErrors)? = second["errors"],
          case let .object(secondError)? = secondErrors.first else {
      return XCTFail("missing field-local payloads: \(response.body)")
    }
    XCTAssertEqual(first["accepted"], .bool(true))
    XCTAssertEqual(second["accepted"], .bool(false))
    XCTAssertEqual(secondError["code"], .string(WorkflowRegistryErrorCode.immutableWorkflow.rawValue))
  }

  func testCompositeExecutorPreservesMixedMutationDocumentOrder() async {
    let recorder = GraphQLDispatchOrderRecorder()
    let executor = CompositeGraphQLDocumentExecutor(
      workflowRegistry: WorkflowRegistryGraphQLDocumentExecutor(
        localProvider: OrderedWorkflowRegistryProvider(recorder: recorder)
      ),
      fallback: OrderedNoteDocumentExecutor(recorder: recorder)
    )
    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation {
        noteDelete(id: "note-1") { accepted }
        deleteMutableWorkflow(input: {target: {workflowId: "alpha"}}) { accepted }
      }
      """,
      isLocallyTrusted: true
    ))
    XCTAssertNil(response.body["errors"], "\(response.body)")
    let order = await recorder.snapshot()
    XCTAssertEqual(order, ["note", "registry"])
  }

  func testUnexpectedAndCancellationErrorsStopLaterMutationDispatch() async {
    for failureId in ["explode", "cancel"] {
      let provider = FailingWorkflowRegistryProvider()
      let executor = WorkflowRegistryGraphQLDocumentExecutor(localProvider: provider)
      let response = await executor.execute(GraphQLDocumentRequest(
        query: """
        mutation {
          first: deleteMutableWorkflow(input: {target: {workflowId: "success"}}) { accepted }
          second: deleteMutableWorkflow(input: {target: {workflowId: "\(failureId)"}}) { accepted }
          third: deleteMutableWorkflow(input: {target: {workflowId: "later"}}) { accepted }
        }
        """,
        isLocallyTrusted: true
      ))
      XCTAssertEqual(errorCode(response), WorkflowRegistryErrorCode.registryIOFailure.rawValue)
      guard case let .object(data)? = response.body["data"],
            case let .object(first)? = data["first"] else {
        return XCTFail("missing completed root data: \(response.body)")
      }
      XCTAssertEqual(first["accepted"], .bool(true))
      XCTAssertNil(data["second"])
      XCTAssertNil(data["third"])
      let calls = await provider.deleteWorkflowIds()
      XCTAssertEqual(calls, ["success", failureId])
    }
  }

  func testUnexpectedAndCancellationRegistrationErrorsMapToRegistryIOFailure() async {
    for failureId in ["explode", "cancel"] {
      let executor = WorkflowRegistryGraphQLDocumentExecutor(
        localProvider: FailingWorkflowRegistryProvider()
      )
      let response = await executor.execute(GraphQLDocumentRequest(
        query: """
        mutation {
          registerMutableWorkflow(input: {
            bundle: {kind: LOCAL_PATH, value: "\(failureId)"}
          }) { accepted }
        }
        """,
        isLocallyTrusted: true
      ))
      XCTAssertEqual(
        errorCode(response),
        WorkflowRegistryErrorCode.registryIOFailure.rawValue,
        "\(response.body)"
      )
    }
  }

  func testLocalPathResolvesRelativeToRequestWorkingDirectory() async {
    let provider = RecordingWorkflowRegistryProvider()
    let executor = WorkflowRegistryGraphQLDocumentExecutor(localProvider: provider)
    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation {
        registerMutableWorkflow(input: {
          bundle: {kind: LOCAL_PATH, value: "relative/bundle"}
        }) {
          accepted
          errors { code }
        }
      }
      """,
      isLocallyTrusted: true,
      localWorkingDirectory: "/workspace/project"
    ))
    XCTAssertNil(response.body["errors"])
    let registeredPath = await provider.registeredBundlePath()
    XCTAssertEqual(registeredPath, "/workspace/project/relative/bundle")
  }

  func testRegistryFieldsRequireMatchingOperationTypeAndCapabilities() async {
    let mutationOnly = WorkflowRegistryGraphQLDocumentExecutor(configuration: WorkflowRegistryGraphQLServerConfig(
      provider: StubWorkflowRegistryProvider(),
      authorizer: StubWorkflowRegistryAuthorizer(capabilities: [.mutateRegistry]),
      managedReferenceResolver: StubManagedReferenceResolver()
    ))
    let mutationWithQueryField = await mutationOnly.execute(GraphQLDocumentRequest(
      query: "mutation { workflows { workflows { workflowId } } }",
      transportCredential: GraphQLTransportCredential("secret")
    ))
    XCTAssertEqual(errorCode(mutationWithQueryField), WorkflowRegistryErrorCode.forbidden.rawValue)

    let readOnly = WorkflowRegistryGraphQLDocumentExecutor(configuration: WorkflowRegistryGraphQLServerConfig(
      provider: StubWorkflowRegistryProvider(),
      authorizer: StubWorkflowRegistryAuthorizer(capabilities: [.readRegistry]),
      managedReferenceResolver: StubManagedReferenceResolver()
    ))
    let queryWithMutationField = await readOnly.execute(GraphQLDocumentRequest(
      query: "query { deleteMutableWorkflow(input: {target: {workflowId: \"alpha\"}}) { accepted } }",
      transportCredential: GraphQLTransportCredential("secret")
    ))
    XCTAssertEqual(errorCode(queryWithMutationField), WorkflowRegistryErrorCode.forbidden.rawValue)
  }

  private func errorCode(_ response: GraphQLDocumentExecutionResponse) -> String? {
    guard case let .array(errors)? = response.body["errors"],
          case let .object(error)? = errors.first,
          case let .object(extensions)? = error["extensions"],
          case let .string(code)? = extensions["code"] else {
      return nil
    }
    return code
  }
}

private actor CredentialRecordingNoteExecutor: GraphQLDocumentExecuting, GraphQLDocumentDomainPreflighting {
  private var credential: GraphQLTransportCredential?
  private var preflightCredential: GraphQLTransportCredential?

  func observedCredential() -> GraphQLTransportCredential? { credential }
  func observedPreflightCredential() -> GraphQLTransportCredential? { preflightCredential }

  func preflight(
    _ request: GraphQLDocumentRequest,
    rootFields: [ParsedGraphQLRootField]
  ) async -> GraphQLDocumentExecutionResponse? {
    preflightCredential = request.transportCredential
    return rootFields.allSatisfy { $0.fieldName == "note" }
      ? nil
      : GraphQLDocumentExecutionResponse(handled: true, body: ["errors": .array([])])
  }

  func execute(_ request: GraphQLDocumentRequest) async -> GraphQLDocumentExecutionResponse {
    credential = request.transportCredential
    return GraphQLDocumentExecutionResponse(
      handled: true,
      body: ["data": .object(["note": .object(["id": .string("note-1")])])]
    )
  }
}

private struct RejectingNoteDocumentExecutor: GraphQLDocumentExecuting, GraphQLDocumentDomainPreflighting {
  func preflight(
    _ request: GraphQLDocumentRequest,
    rootFields: [ParsedGraphQLRootField]
  ) async -> GraphQLDocumentExecutionResponse? {
    GraphQLDocumentExecutionResponse(handled: true, body: [
      "errors": .array([.object([
        "message": .string("note mutation forbidden"),
        "extensions": .object(["code": .string(WorkflowRegistryErrorCode.forbidden.rawValue)])
      ])])
    ])
  }

  func execute(_ request: GraphQLDocumentRequest) async -> GraphQLDocumentExecutionResponse {
    XCTFail("fallback execution must not occur after failed preflight")
    return GraphQLDocumentExecutionResponse(handled: true, body: [:])
  }
}

private actor RecordingWorkflowRegistryProvider: WorkflowRegistryGraphQLProviding {
  private var activationCalls = 0
  private var deleteCalls = 0
  private var listCalls = 0
  private var registeredPath: String?

  func activationCallCount() -> Int { activationCalls }
  func deleteCallCount() -> Int { deleteCalls }
  func listCallCount() -> Int { listCalls }
  func registeredBundlePath() -> String? { registeredPath }

  func workflows(filter: WorkflowRegistryFilter) async throws -> [GraphQLWorkflowRegistryEntry] {
    listCalls += 1
    return []
  }

  func workflow(target: WorkflowRegistryTarget) async throws -> GraphQLWorkflowRegistryEntry {
    throw WorkflowRegistryError(code: .workflowNotFound, message: "not found")
  }

  func registerMutableWorkflow(
    input: GraphQLRegisterMutableWorkflowInput,
    resolvedBundleURL: URL
  ) async throws -> GraphQLWorkflowMutationPayload {
    registeredPath = resolvedBundleURL.path
    return GraphQLWorkflowMutationPayload(accepted: true)
  }

  func updateMutableWorkflow(
    input: GraphQLUpdateMutableWorkflowInput,
    resolvedBundleURL: URL
  ) async throws -> GraphQLWorkflowMutationPayload {
    GraphQLWorkflowMutationPayload(accepted: true)
  }

  func deleteMutableWorkflow(
    input: GraphQLDeleteMutableWorkflowInput
  ) async throws -> GraphQLWorkflowMutationPayload {
    deleteCalls += 1
    return GraphQLWorkflowMutationPayload(accepted: true)
  }

  func setWorkflowActivation(
    input: GraphQLSetWorkflowActivationInput,
    state: WorkflowActivationState
  ) async throws -> GraphQLWorkflowMutationPayload {
    activationCalls += 1
    return GraphQLWorkflowMutationPayload(accepted: true)
  }

  func consolidateWorkflows(
    input: GraphQLConsolidateWorkflowsInput,
    resolvedBundleURL: URL
  ) async throws -> GraphQLWorkflowMutationPayload {
    GraphQLWorkflowMutationPayload(accepted: true)
  }
}

private actor GraphQLDispatchOrderRecorder {
  private var events: [String] = []

  func append(_ event: String) {
    events.append(event)
  }

  func snapshot() -> [String] {
    events
  }
}

private struct OrderedNoteDocumentExecutor: GraphQLDocumentExecuting, GraphQLDocumentDomainPreflighting {
  var recorder: GraphQLDispatchOrderRecorder

  func preflight(
    _ request: GraphQLDocumentRequest,
    rootFields: [ParsedGraphQLRootField]
  ) async -> GraphQLDocumentExecutionResponse? {
    rootFields.allSatisfy { $0.fieldName == "noteDelete" }
      ? nil
      : GraphQLDocumentExecutionResponse(handled: true, body: ["errors": .array([])])
  }

  func execute(_ request: GraphQLDocumentRequest) async -> GraphQLDocumentExecutionResponse {
    await recorder.append("note")
    let responseKey = request.parsedRootFields?.first?.responseKey ?? "noteDelete"
    return GraphQLDocumentExecutionResponse(
      handled: true,
      body: ["data": .object([responseKey: .object(["accepted": .bool(true)])])]
    )
  }
}

private struct OrderedWorkflowRegistryProvider: WorkflowRegistryGraphQLProviding {
  var recorder: GraphQLDispatchOrderRecorder

  func workflows(filter: WorkflowRegistryFilter) async throws -> [GraphQLWorkflowRegistryEntry] { [] }

  func workflow(target: WorkflowRegistryTarget) async throws -> GraphQLWorkflowRegistryEntry {
    throw WorkflowRegistryError(code: .workflowNotFound, message: "not found")
  }

  func registerMutableWorkflow(
    input: GraphQLRegisterMutableWorkflowInput,
    resolvedBundleURL: URL
  ) async throws -> GraphQLWorkflowMutationPayload {
    GraphQLWorkflowMutationPayload(accepted: true)
  }

  func updateMutableWorkflow(
    input: GraphQLUpdateMutableWorkflowInput,
    resolvedBundleURL: URL
  ) async throws -> GraphQLWorkflowMutationPayload {
    GraphQLWorkflowMutationPayload(accepted: true)
  }

  func deleteMutableWorkflow(
    input: GraphQLDeleteMutableWorkflowInput
  ) async throws -> GraphQLWorkflowMutationPayload {
    await recorder.append("registry")
    return GraphQLWorkflowMutationPayload(accepted: true)
  }

  func setWorkflowActivation(
    input: GraphQLSetWorkflowActivationInput,
    state: WorkflowActivationState
  ) async throws -> GraphQLWorkflowMutationPayload {
    GraphQLWorkflowMutationPayload(accepted: true)
  }

  func consolidateWorkflows(
    input: GraphQLConsolidateWorkflowsInput,
    resolvedBundleURL: URL
  ) async throws -> GraphQLWorkflowMutationPayload {
    GraphQLWorkflowMutationPayload(accepted: true)
  }
}
