import Foundation
import GoogleServiceGatewayCore
import GatewaySDKKit
import RielaAdapters
import RielaAddonSupport
import RielaCore
import XCTest
@testable import RielaCLI

final class BuiltinGatewayJSONBehaviorTests: XCTestCase {
  func testWriteTiersKeepSuccessfulProviderResultWhenPostprocessFails() async throws {
    var cases = [
      GraphQLWriteCase(name: "riela/wrike-gateway-write", document: "mutation { updateTask { task { id } } }"),
      GraphQLWriteCase(name: "riela/gmail-gateway-draft", document: "mutation { sendMessage { operation } }"),
      GraphQLWriteCase(name: "riela/gmail-gateway-sender", document: "mutation { sendMessage { operation } }"),
      GraphQLWriteCase(name: "riela/google-analytics-gateway-write",
                       document: "mutation { gtmPublishVersion(input: { path: \"v\" }) { path } }")
    ]
    #if os(macOS)
    cases.append(GraphQLWriteCase(
      name: "riela/notion-gateway-write",
      document: "mutation { archivePage(id: \"00000000-0000-0000-0000-000000000001\") }",
      bindings: ["NOTION_API_KEY": .object(["fromEnv": .string("BOUND_NOTION")])]
    ))
    #endif

    for testCase in cases {
      let gateway = RecordingGatewayGraphQLRunner(
        response: #"{"data":{"result":{"id":"created-1"}}}"#
      )
      let input = WorkflowAddonExecutionInput(
        workflowId: "gateway-json-behavior",
        stepId: "write",
        nodeId: "write",
        addon: .init(name: testCase.name, version: "1", config: [
          "queryTemplate": .string(testCase.document),
          "postprocess": .array([
            .object(["pick": .string("/data/missing")]),
            .object(["take": .integer(1)])
          ])
        ], env: testCase.bindings),
        resolvedInputPayload: [:]
      )
      let output = try await BuiltinWorkflowAddonResolver(
        environment: ["BOUND_NOTION": "synthetic-token"],
        localGatewayGraphQLRunner: gateway.runner
      ).execute(input, context: .init())

      XCTAssertEqual(gateway.allCalls().count, 1, testCase.name)
      XCTAssertTrue(output.completionPassed, testCase.name)
      XCTAssertEqual(output.when["postprocessFailed"], true, testCase.name)
      XCTAssertEqual(output.payload["postprocess"], .object([
        "status": .string("failed"),
        "reason": .string("input-shape-or-limit"),
        "retryProvider": .bool(false)
      ]), testCase.name)
      XCTAssertEqual(output.payload["data"], .object(["result": .object(["id": .string("created-1")])]), testCase.name)
    }
  }

  func testExplicitNullAndEmptyArrayArgumentsReachProviderUnchanged() async throws {
    let response = #"{"data":{"threads":{"nodes":[]}}}"#
    let gateway = RecordingGatewayGraphQLRunner(response: response)
    let input = WorkflowAddonExecutionInput(
      workflowId: "gateway-json-behavior",
      stepId: "read",
      nodeId: "read",
      addon: .init(name: "riela/gmail-gateway-reader", version: "1", config: [
        "operation": .string("threads"),
        "arguments": .object(["input": .object([
          "accountId": .string("personal"),
          "after": .null,
          "labelIds": .array([])
        ])]),
        "postprocess": .array([.object(["pick": .string("/data/threads/nodes")])])
      ]), resolvedInputPayload: [:]
    )
    let output = try await BuiltinWorkflowAddonResolver(environment: [:], localGatewayGraphQLRunner: gateway.runner)
      .execute(input, context: .init())

    XCTAssertEqual(gateway.allCalls().count, 1)
    let call = try XCTUnwrap(gateway.lastCall())
    let variables = try JSONDecoder().decode(
      RielaCore.JSONValue.self,
      from: Data(try XCTUnwrap(call.variablesJSON).utf8)
    )
    guard case let .object(root) = variables,
          case let .object(arguments)? = root["input"] else {
      return XCTFail("the provider variables must contain the typed input object")
    }
    XCTAssertEqual(arguments["after"], .null, "explicit null must remain present")
    XCTAssertEqual(arguments["labelIds"], .array([]), "the empty list must remain present")
    XCTAssertNil(arguments["first"], "a missing field must remain omitted")
    XCTAssertEqual(output.payload["processed"], .array([]))
    XCTAssertNotEqual(output.when["postprocessFailed"], true)
  }

  func testOversizedArgumentsAreBlockedBeforeProvider() async throws {
    let gateway = RecordingGatewayGraphQLRunner(response: #"{"data":{}}"#)
    let oversized = String(repeating: "a", count: GatewayJSONLimits.maximumEncodedBytes)
    let input = WorkflowAddonExecutionInput(
      workflowId: "gateway-json-behavior",
      stepId: "read",
      nodeId: "read",
      addon: .init(name: "riela/gmail-gateway-reader", version: "1", config: [
        "operation": .string("threads"),
        "arguments": .object(["input": .object(["query": .string(oversized)])])
      ]), resolvedInputPayload: [:]
    )

    do {
      _ = try await BuiltinWorkflowAddonResolver(environment: [:], localGatewayGraphQLRunner: gateway.runner)
        .execute(input, context: .init())
      XCTFail("an argument document over 8 MiB must be rejected")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
    }
    XCTAssertTrue(gateway.allCalls().isEmpty)
  }

  func testPostprocessEntryLimitFailsAfterSingleProviderCall() async throws {
    let rows: [RielaCore.JSONValue] = (0..<10_001).map { index in
      RielaCore.JSONValue.object(["id": .string(String(describing: index)), "keep": .bool(true)])
    }
    let response = try RielaCore.JSONValue.object(["data": .object([
      "threads": .object(["nodes": .array(rows)])
    ])]).compactJSONString()
    let gateway = RecordingGatewayGraphQLRunner(response: response)
    let input = WorkflowAddonExecutionInput(
      workflowId: "gateway-json-behavior",
      stepId: "read",
      nodeId: "read",
      addon: .init(name: "riela/gmail-gateway-reader", version: "1", config: [
        "operation": .string("threads"),
        "arguments": .object(["input": .object(["accountId": .string("personal")])]),
        "postprocess": .array([
          .object(["pick": .string("/data/threads/nodes")]),
          .object(["filter": .object(["path": .string("/keep"), "equals": .bool(true)])])
        ])
      ]), resolvedInputPayload: [:]
    )
    let output = try await BuiltinWorkflowAddonResolver(environment: [:], localGatewayGraphQLRunner: gateway.runner)
      .execute(input, context: .init())

    XCTAssertEqual(gateway.allCalls().count, 1)
    XCTAssertTrue(output.completionPassed)
    XCTAssertEqual(output.when["postprocessFailed"], true)
    let expectedPostprocess: RielaCore.JSONValue = .object([
      "status": .string("failed"),
      "reason": .string("input-shape-or-limit"),
      "retryProvider": .bool(false)
    ])
    XCTAssertEqual(output.payload["postprocess"], expectedPostprocess)
    XCTAssertNotNil(output.payload["data"])
  }

  #if os(macOS)
  func testGoogleDocumentsWriteKeepsSuccessfulResultWhenPostprocessFails() async throws {
    let gateway = RecordingGoogleDocumentsGatewayRunner(response: #"{"ok":true,"data":{"cleared":true}}"#)
    let input = WorkflowAddonExecutionInput(
      workflowId: "gateway-json-behavior",
      stepId: "write",
      nodeId: "write",
      addon: .init(name: "riela/google-sheet-gateway-write", version: "1", config: [
        "command": .string("values clear"),
        "argsTemplate": .object([
          "spreadsheet-id": .string("SHEET-1"), "range": .string("Sheet1!A1"), "confirm-clear": .bool(true)
        ]),
        "postprocess": .array([
          .object(["pick": .string("/data/missing")]),
          .object(["take": .integer(1)])
        ])
      ]), resolvedInputPayload: [:]
    )
    let output = try await BuiltinWorkflowAddonResolver(
      environment: [:], googleDocumentsGatewayRunner: gateway.runner
    ).execute(input, context: .init())

    XCTAssertEqual(gateway.allCalls().count, 1)
    XCTAssertTrue(output.completionPassed)
    XCTAssertEqual(output.when["postprocessFailed"], true)
    XCTAssertEqual(output.payload["postprocess"], .object([
      "status": .string("failed"),
      "reason": .string("input-shape-or-limit"),
      "retryProvider": .bool(false)
    ]))
    XCTAssertEqual(output.payload["data"], .object(["cleared": .bool(true)]))
  }

  func testGoogleServiceWriteKeepsSuccessfulResultWhenPostprocessFails() async throws {
    let client = BehaviorGoogleServiceGatewayClient()
    let input = WorkflowAddonExecutionInput(
      workflowId: "gateway-json-behavior",
      stepId: "write",
      nodeId: "write",
      addon: .init(name: "riela/google-service-gateway-write", version: "1", config: [
        "operation": .string("services.enable"),
        "arguments": .object(["project": .string("sample-project"), "service": .string("calendar")]),
        "postprocess": .array([
          .object(["pick": .string("/data/missing")]),
          .object(["take": .integer(1)])
        ])
      ], env: ["GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN": .object(["fromEnv": .string("TEST_TOKEN")])]),
      resolvedInputPayload: [:]
    )
    let output = try await BuiltinWorkflowAddonResolver(
      environment: ["TEST_TOKEN": "synthetic-token"],
      googleServiceGatewayClientFactory: { _ in client }
    ).execute(input, context: .init())

    let callCount = await client.callCount()
    XCTAssertEqual(callCount, 1)
    XCTAssertTrue(output.completionPassed)
    XCTAssertEqual(output.when["postprocessFailed"], true)
    XCTAssertEqual(output.payload["postprocess"], .object([
      "status": .string("failed"),
      "reason": .string("input-shape-or-limit"),
      "retryProvider": .bool(false)
    ]))
    XCTAssertEqual(output.payload["data"], .object(["kind": .string("enabled")]))
  }
  #endif

  func testAppleMutationWriteKeepsSuccessfulResultWhenPostprocessFails() async throws {
    let calls = BehaviorCallCounter()
    let resolver = BuiltinWorkflowAddonResolver(environment: [:], appleGatewayRunner: { _, _, _ in
      calls.increment()
      return AppleGatewayProcessOutput(stdout: #"{"data":{"createEvent":{"id":"created-1","calendarId":"cal-1","title":"Created","startDate":"2026-07-07T10:00:00Z","endDate":"2026-07-07T11:00:00Z"}}}"#, stderr: "")
    })
    let input = WorkflowAddonExecutionInput(
      workflowId: "gateway-json-behavior",
      stepId: "write",
      nodeId: "write",
      addon: .init(name: "riela/event-create", version: "1", config: [
        "postprocess": .array([
          .object(["pick": .string("/data/missing")]),
          .object(["take": .integer(1)])
        ])
      ], inputs: [
        "calendarId": .string("cal-1"), "title": .string("Created"),
        "startDate": .string("2026-07-07T10:00:00Z"), "endDate": .string("2026-07-07T11:00:00Z")
      ]), resolvedInputPayload: [:]
    )
    let output = try await resolver.execute(input, context: .init())

    XCTAssertEqual(calls.value, 1)
    XCTAssertTrue(output.completionPassed)
    XCTAssertEqual(output.when["postprocessFailed"], true)
    XCTAssertEqual(output.payload["postprocess"], .object([
      "status": .string("failed"),
      "reason": .string("input-shape-or-limit"),
      "retryProvider": .bool(false)
    ]))
    XCTAssertNotNil(output.payload["appleCalendar"])
  }

  func testContainerReadersRetainPaginationMetadataBesideProcessedData() async throws {
    let cases = [
      ContainerPaginationCase(name: "riela/x-gateway-read", query: "{ homeTimeline { pageInfo { nextToken } } }",
                              namespace: "xGateway", resultKey: "homeTimeline", cursorKey: "nextToken"),
      ContainerPaginationCase(name: "riela/gmail-gateway-read", query: "{ accounts { id } }",
                              namespace: "gmailGateway", resultKey: "accounts", cursorKey: "nextPageToken")
    ]

    for testCase in cases {
      let runner = BehaviorContainerRunner()
      let input = WorkflowAddonExecutionInput(
        workflowId: "gateway-json-behavior",
        stepId: "read",
        nodeId: "read",
        addon: .init(name: testCase.name, version: "1", config: [
          "queryTemplate": .string(testCase.query),
          "runnerKind": .string("docker"),
          "networkPolicy": .string("denied"),
          "postprocess": .array([.object(["pick": .string("/\(testCase.namespace)/data/data/\(testCase.resultKey)")])])
        ]), resolvedInputPayload: [:]
      )
      let output = try await BuiltinWorkflowAddonResolver(environment: [:], containerProcessRunner: runner)
        .execute(input, context: .init())
      let callCount = await runner.callCount()

      XCTAssertEqual(callCount, 1, testCase.name)
      XCTAssertNotNil(output.payload["processed"], testCase.name)
      guard case let .object(gateway)? = output.payload[testCase.namespace],
            case let .object(envelope)? = gateway["data"],
            case let .object(data)? = envelope["data"] else {
        return XCTFail("\(testCase.name) must retain the gateway response")
      }
      if testCase.name == "riela/x-gateway-read" {
        guard case let .object(homeTimeline)? = data["homeTimeline"],
              case let .object(pageInfo)? = homeTimeline["pageInfo"] else {
          return XCTFail("X container pagination metadata must remain in the response")
        }
        XCTAssertEqual(pageInfo[testCase.cursorKey], .string("cursor-2"), testCase.name)
      } else {
        guard case let .object(pageInfo)? = data["pageInfo"] else {
          return XCTFail("Gmail container pagination metadata must remain in the response")
        }
        XCTAssertEqual(pageInfo[testCase.cursorKey], .string("cursor-2"), testCase.name)
      }
    }
  }
}

private struct GraphQLWriteCase {
  var name: String
  var document: String
  var bindings: JSONObject?
}

private struct ContainerPaginationCase {
  var name: String
  var query: String
  var namespace: String
  var resultKey: String
  var cursorKey: String
}

private final class BehaviorCallCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = 0

  var value: Int { lock.withLock { storage } }

  func increment() { lock.withLock { storage += 1 } }
}

private actor BehaviorContainerRunner: LocalProcessRunning {
  private var calls = 0

  func callCount() -> Int { calls }

  func run(configuration _: LocalProcessConfiguration, stdin _: String, deadline _: Date?) async throws -> LocalProcessResult {
    calls += 1
    return .init(
      stdout: #"{"data":{"homeTimeline":{"pageInfo":{"nextToken":"cursor-2"}},"accounts":[{"id":"account-1"}],"pageInfo":{"nextPageToken":"cursor-2"}}}"#,
      stderr: "",
      terminationStatus: 0
    )
  }
}

#if os(macOS)
private actor BehaviorGoogleServiceGatewayClient: GoogleServiceGatewayAddonClient {
  private var recordedCallCount = 0

  func callCount() -> Int { recordedCallCount }

  func listServices(_: ListServicesRequest) async throws -> GoogleServiceGatewayCore.JSONValue {
    recordedCallCount += 1
    return .object([:])
  }

  func getService(project _: String, service _: String) async throws -> GoogleServiceGatewayCore.JSONValue {
    recordedCallCount += 1
    return .object([:])
  }

  func getOperation(_: String) async throws -> GoogleServiceGatewayCore.JSONValue {
    recordedCallCount += 1
    return .object([:])
  }

  func enable(project _: String, service _: String, options _: MutationOptions) async throws -> GoogleServiceGatewayCore.JSONValue {
    recordedCallCount += 1
    return .object(["kind": .string("enabled")])
  }

  func disable(project _: String, service _: String, disableDependents _: Bool, checkUsage _: Bool,
               options _: MutationOptions) async throws -> GoogleServiceGatewayCore.JSONValue {
    recordedCallCount += 1
    return .object([:])
  }

  func batchEnable(project _: String, services _: [String], options _: MutationOptions) async throws -> GoogleServiceGatewayCore.JSONValue {
    recordedCallCount += 1
    return .object([:])
  }
}
#endif
