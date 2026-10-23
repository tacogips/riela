import Foundation
import GatewaySDKKit
import RielaAdapters
import RielaCore
import XCTest
@testable import RielaCLI

final class LegacyGatewayJSONRequestTests: XCTestCase {
  func testInlineReaderPreservesTypedNestedValuesEnumsAndLiteralTemplates() throws {
    let catalog = try XCTUnwrap(BuiltinGmailGatewayCLIAddon.reader.descriptor.catalog)()
    let source = "quoted \" } mutation { sendMessage } # {{secret}} $input\n日本語"
    let built = try BuiltinGatewayJSONRequest.document(config: [
      "operation": .string("threads"), "arguments": .object(["input": .object([
        "accountId": .string("personal"), "query": .string("{{input.query}}"),
        "direction": .string("RECEIVED"), "starred": .bool(true), "first": .integer(5),
        "labelIds": .array([.string("INBOX"), .string("CUSTOM")]), "after": .null
      ])])
    ], variables: ["input": .object(["query": .string(source)])], catalog: catalog, addonName: "fixture")
    let document = try BuiltinGatewayJSONRequest.inlineReaderDocument(built, catalog: catalog)
    let parsed = try GatewayGraphQLParser.parse(document)
    XCTAssertTrue(parsed.variableDefinitions.isEmpty)
    let checked = try GatewayGraphQLValidator(catalog: catalog).validate(parsed)
    let arguments = try XCTUnwrap(checked.rootFields.first?.arguments["input"])
    guard case let .object(input) = arguments else { return XCTFail("missing typed input") }
    XCTAssertEqual(input["query"], .string(source))
    XCTAssertEqual(input["direction"], .string("RECEIVED"))
    XCTAssertEqual(input["starred"], .bool(true))
    XCTAssertEqual(input["first"], .int(5))
    XCTAssertEqual(input["labelIds"], .array([.string("INBOX"), .string("CUSTOM")]))
    XCTAssertTrue(document.contains("direction: RECEIVED"))
  }

  func testInlineReaderRejectsMutationAndTrailingOperations() throws {
    let catalog = try XCTUnwrap(BuiltinGmailGatewayCLIAddon.reader.descriptor.catalog)()
    for document in ["mutation { sendMessage { id } }", "query { accounts { id } } mutation { sendMessage { id } }",
                     "query($id: ID!, $id: ID!) { account(id: $id) { id } }"] {
      XCTAssertThrowsError(try BuiltinGatewayJSONRequest.inlineReaderDocument(
        .init(document: document, variables: [:]), catalog: catalog)) { error in
        XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      }
    }
  }

  func testLegacyContainersAcceptJSONBeforeStartingRuntimeAndApplyPostprocess() async throws {
    for gateway in [ContainerGatewayAddon.gmailRead, .xRead] {
      let runner = LegacyJSONRecordingRunner()
      let isGmail = gateway == .gmailRead
      let operation = isGmail ? "account" : "accountMe"
      let arguments: JSONObject = isGmail ? ["id": .string("{{input.id}}")] : [:]
      let request = WorkflowAddonExecutionInput(workflowId: "fixture", stepId: "fetch", nodeId: "fetch",
        addon: .init(name: gateway.rawValue, config: [
          "operation": .string(operation), "arguments": .object(arguments), "selection": .array([.string("id")]),
          "runnerKind": .string("docker"), "networkPolicy": .string("denied"),
          "postprocess": .array([.object(["pick": .string("/\(gateway.namespace)/data/data/value")])])
        ]), resolvedInputPayload: ["id": .string("personal-{{literal}}\"")])
      let output = try await BuiltinWorkflowAddonResolver(environment: [:], containerProcessRunner: runner)
        .execute(request, context: .init())
      let calls = await runner.calls
      XCTAssertEqual(calls.count, 1)
      let call = try XCTUnwrap(calls.first)
      let index = try XCTUnwrap(call.arguments.firstIndex(of: isGmail ? "--query" : "query"))
      let document = call.arguments[index + 1]
      XCTAssertEqual(try GatewayGraphQLParser.parse(document).operationType, .query)
      if isGmail { XCTAssertTrue(document.contains(try GatewayJSONValue.string("personal-{{literal}}\"").jsonString())) }
      XCTAssertEqual(output.payload["processed"], .string("checked"))
      XCTAssertEqual(output.when["postprocessPassed"], true)
    }
  }

  func testJSONDocumentSizeBoundaryBeforeContainerLaunch() async throws {
    for gateway in [ContainerGatewayAddon.gmailRead, .xRead] {
      for size in [119_000, 121_000] {
        let runner = LegacyJSONRecordingRunner()
        let isGmail = gateway == .gmailRead
        let arguments: JSONObject = [isGmail ? "id" : "paginationToken": .string(String(repeating: "a", count: size))]
        do {
          _ = try await BuiltinWorkflowAddonResolver(environment: [:], containerProcessRunner: runner)
            .execute(.init(workflowId: "fixture", stepId: "fetch", nodeId: "fetch",
              addon: .init(name: gateway.rawValue, config: [
                "operation": .string(isGmail ? "account" : "homeTimeline"), "arguments": .object(arguments),
                "selection": .array([.string(isGmail ? "id" : "posts.id")]), "runnerKind": .string("docker")
              ])), context: .init())
          XCTAssertLessThan(size, 120_000, "oversized argv must not dispatch")
        } catch {
          XCTAssertGreaterThan(size, 120_000, "below-cap request must launch")
          XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
          if !isGmail {
            XCTAssertEqual((error as? AdapterExecutionError)?.message,
              "gateway JSON document exceeds the legacy container argument limit")
          }
        }
        let calls = await runner.calls
        XCTAssertEqual(calls.count, size < 120_000 ? 1 : 0)
      }
    }
  }

  func testCatalogRequestsRejectCompatibilitySelectKey() throws {
    let catalog = try XCTUnwrap(BuiltinGmailGatewayCLIAddon.reader.descriptor.catalog)()
    XCTAssertThrowsError(try BuiltinGatewayJSONRequest.document(config: [
      "operation": .string("accounts"), "select": .object(["id": .bool(true)])
    ], variables: [:], catalog: catalog, addonName: "fixture")) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
    }
  }

  func testInvalidJSONOperationNeverStartsContainer() async throws {
    let runner = LegacyJSONRecordingRunner()
    do {
      _ = try await BuiltinWorkflowAddonResolver(environment: [:], containerProcessRunner: runner)
        .execute(.init(workflowId: "fixture", stepId: "fetch", nodeId: "fetch",
          addon: .init(name: "riela/gmail-gateway-read", config: [
            "operation": .string("sendMessage"), "arguments": .object([:]), "runnerKind": .string("docker")
          ])), context: .init())
      XCTFail("reader must refuse send before starting its runtime")
    } catch { XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked) }
    let calls = await runner.calls
    XCTAssertTrue(calls.isEmpty)
  }
}

private actor LegacyJSONRecordingRunner: LocalProcessRunning {
  private(set) var calls: [LocalProcessConfiguration] = []
  func run(configuration: LocalProcessConfiguration, stdin: String, deadline: Date?) async throws -> LocalProcessResult {
    calls.append(configuration)
    return .init(stdout: #"{"data":{"value":"checked"}}"#, stderr: "", terminationStatus: 0)
  }
}
