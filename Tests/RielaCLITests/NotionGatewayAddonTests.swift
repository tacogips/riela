import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class NotionGatewayAddonTests: XCTestCase {
  private func input(_ name: String, query: String, env: JSONObject? = nil) -> WorkflowAddonExecutionInput {
    WorkflowAddonExecutionInput(workflowId: "notion-test", stepId: "notion-step", nodeId: "notion-node",
      addon: WorkflowNodeAddonRef(name: name, version: "1", config: ["queryTemplate": .string(query),
        "variablesTemplate": .object(["id": .string("{{pageId}}")])], env: env),
      variables: ["pageId": .string("synthetic-page")], resolvedInputPayload: [:])
  }

  func testPinnedRoleVariablesAndOnlyExplicitCredentialBinding() async throws {
    for (name, tier) in [("riela/notion-gateway-read", "reader"), ("riela/notion-gateway-write", "writer")] {
      let recorder = RecordingGatewayGraphQLRunner(response: #"{"data":{"page":{"id":"synthetic-page","has_more":true,"next_cursor":"cursor"}},"errors":[],"extensions":{"requestId":"synthetic"}}"#)
      let resolver = BuiltinWorkflowAddonResolver(environment: ["NOTION_API_KEY": "unbound", "BOUND_NOTION": "synthetic-token", "UNRELATED_SECRET": "excluded"],
        localGatewayGraphQLRunner: recorder.runner)
      let result = try await resolver.execute(input(name, query: "query($id:ID!){page(id:$id)}", env: ["NOTION_API_KEY": .object(["fromEnv": .string("BOUND_NOTION")])]), context: AdapterExecutionContext())
      let call = try XCTUnwrap(recorder.lastCall())
      XCTAssertEqual(call.tier, tier)
      XCTAssertEqual(call.environment["NOTION_API_KEY"], "synthetic-token")
      XCTAssertNil(call.environment["UNRELATED_SECRET"])
      XCTAssertNil(call.environment["BOUND_NOTION"])
      XCTAssertEqual(call.variablesJSON, #"{"id":"synthetic-page"}"#)
      XCTAssertEqual(result.payload["data"], .object(["page": .object(["id": .string("synthetic-page"), "has_more": .bool(true), "next_cursor": .string("cursor")])]))
      XCTAssertEqual(result.provider, "notion-gateway")
    }
  }

  func testEnvironmentTargetRejectsBeforeDispatch() async throws {
    let recorder = RecordingGatewayGraphQLRunner()
    do {
      _ = try await BuiltinWorkflowAddonResolver(localGatewayGraphQLRunner: recorder.runner).execute(
        input("riela/notion-gateway-read", query: "{page(id:\"x\")}", env: ["PATH": .string("BAD")]), context: AdapterExecutionContext())
      XCTFail("invalid credential target accepted")
    } catch let error as AdapterExecutionError { XCTAssertEqual(error.code, .policyBlocked) }
    XCTAssertTrue(recorder.allCalls().isEmpty)
  }

  func testGatewayErrorDoesNotReplayAndRetainsSafeOutcome() async throws {
    let recorder = RecordingGatewayGraphQLRunner(response: #"{"data":{},"errors":[{"message":"Notion returned HTTP503 [notionDiagnostics mutationOutcome=unknown retryAfterSeconds=3]"}]}"#)
    do {
      _ = try await BuiltinWorkflowAddonResolver(localGatewayGraphQLRunner: recorder.runner).execute(
        input("riela/notion-gateway-write", query: "mutation{archivePage(id:\"x\")}"), context: AdapterExecutionContext())
      XCTFail("error accepted")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .providerError)
      XCTAssertTrue(error.message.contains("mutationOutcome=unknown"))
      XCTAssertTrue(error.message.contains("retryAfterSeconds=3"))
    }
    XCTAssertEqual(recorder.allCalls().count, 1)
  }

  #if os(macOS)
  func testLinkedWriterValidatesPagePositionBeforeCredentialsOrNetwork() async throws {
    let result = try await runNativeGatewayCLI(.init(gateway: .notion, role: "writer", arguments: [
      "graphql", "--query", "mutation($position:JSON){createPage(parentId:\"00000000-0000-0000-0000-000000000001\",title:\"fixture\",position:$position)}",
      "--variables", #"{"position":{"type":"invalid"}}"#
    ]), environment: [:])
    XCTAssertNotEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("Invalid page insertion position"))
    XCTAssertFalse(result.stdout.contains("AUTHENTICATION_REQUIRED"))
  }

  func testLinkedReaderRejectsMutationWithoutCredentialsOrNetwork() async throws {
    do {
      _ = try await BuiltinWorkflowAddonResolver(environment: [:]).execute(
        input("riela/notion-gateway-read", query: "mutation{archivePage(id:\"00000000-0000-0000-0000-000000000001\")}"), context: AdapterExecutionContext())
      XCTFail("reader mutation accepted")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .providerError)
      XCTAssertFalse(error.message.contains("AUTHENTICATION_REQUIRED"))
    }
    let schema = try await runNativeGatewayCLI(.init(gateway: .notion, role: "reader", arguments: ["schema"]), environment: [:])
    XCTAssertEqual(schema.exitCode, 0)
    XCTAssertFalse(schema.stdout.contains("createPage"))
    let writerSchema = try await runNativeGatewayCLI(.init(gateway: .notion, role: "writer", arguments: ["schema"]), environment: [:])
    let createPage = try XCTUnwrap(writerSchema.stdout.split(separator: "\n").first { $0.contains("createPage(") })
    XCTAssertTrue(createPage.contains("position: JSON"))
    XCTAssertTrue(writerSchema.stdout.contains("createFileUpload"))
    XCTAssertTrue(writerSchema.stdout.contains("sendFileUpload"))
    XCTAssertTrue(writerSchema.stdout.contains("position: JSON"))
    XCTAssertTrue(writerSchema.stdout.contains("createAttachmentUpload"))
    XCTAssertTrue(writerSchema.stdout.contains("sendAttachmentUpload"))
    XCTAssertTrue(schema.stdout.contains("downloadBlockFile"))
    XCTAssertFalse(schema.stdout.contains("createAttachmentUpload"))
    XCTAssertTrue(schema.stdout.contains("downloadBlockImage"))
    XCTAssertFalse(schema.stdout.contains("sendFileUpload"))
  }
  #endif
}
