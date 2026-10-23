import Foundation
import KaibaClient
import RielaCore
import XCTest
@testable import RielaKaibaAddons

final class KaibaStructuredArgumentsTests: XCTestCase {
  func testNamedOperationUsesStructuredArgumentsWithoutFlatOverridesOrReexpansion() async throws {
    let transport = KaibaHTTPFixture()
    let source = "body {{literal}} \" } mutation { removeNote }"
    let input = WorkflowAddonExecutionInput(workflowId: "fixture", stepId: "create", nodeId: "create",
      addon: .init(name: "kaiba/note-create", config: ["arguments": .object([
        "bodyMarkdown": .string("{{input.body}}"), "readOnly": .bool(true),
        "tags": .array([.string("typed")])])]),
      variables: ["bodyMarkdown": .string("unrelated flat override"), "literal": .string("must-not-expand")],
      resolvedInputPayload: ["body": .string(source)])
    let output = try await KaibaAddonCatalog.executeForTesting(input, client: fixtureKaibaClient(transport), environment: [:])
    XCTAssertEqual(output.payload["noteId"], .string("note-1"))
    let request = try XCTUnwrap(transport.requests.first)
    let body = try JSONDecoder().decode(JSONObject.self, from: request.body)
    guard case let .object(variables)? = body["variables"], case let .object(fields)? = variables["input"] else {
      return XCTFail("missing typed request variables")
    }
    XCTAssertEqual(fields["bodyMarkdown"], .string(source))
    XCTAssertEqual(fields["readOnly"], .bool(true))
    XCTAssertFalse(try XCTUnwrap(String(data: request.body, encoding: .utf8)).contains("must-not-expand"))
  }

  func testMalformedMixedAndConnectionArgumentsFailBeforeTransport() async throws {
    let configs: [JSONObject] = [
      ["arguments": .array([])],
      ["arguments": .object(["bodyMarkdown": .string("checked")]), "title": .string("mixed")],
      ["arguments": .object(["bodyMarkdown": .string("checked"), "endpoint": .string("http://wrong.example")])],
      ["arguments": .object(["bodyMarkdown": .string("checked"), "kaibaInstanceId": .string("other")])]
    ]
    for config in configs {
      let transport = KaibaHTTPFixture()
      do {
        _ = try await KaibaAddonCatalog.executeForTesting(.init(workflowId: "fixture", stepId: "create", nodeId: "create",
          addon: .init(name: "kaiba/note-create", config: config)), client: fixtureKaibaClient(transport), environment: [:])
        XCTFail("invalid arguments must not dispatch")
      } catch { XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked) }
      XCTAssertTrue(transport.requests.isEmpty)
    }
  }

  func testStructuredDocumentsAndOperationNamesCannotBeTemplates() async throws {
    for addonName in ["kaiba/note-graphql-document", "kaiba/note-graphql-remote"] {
      for key in ["query", "document", "operationName"] {
        let transport = KaibaHTTPFixture()
        var arguments: JSONObject = key == "document" ? [:] : ["query": .string("query Fixture { fixture }")]
        arguments[key] = .string("{{input.source}}")
        do {
          _ = try await KaibaAddonCatalog.executeForTesting(.init(workflowId: "fixture", stepId: "read", nodeId: "read",
            addon: .init(name: addonName, config: ["arguments": .object(arguments)]),
            resolvedInputPayload: ["source": .string(key == "operationName" ? "Fixture" : "query Fixture { fixture }")]),
            client: fixtureKaibaClient(transport), environment: [:])
          XCTFail("document structure must remain authored")
        } catch { XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked) }
        XCTAssertTrue(transport.requests.isEmpty)
      }
    }
  }

  func testStructuredArgumentsRejectExplicitAddonInputs() async throws {
    let transport = KaibaHTTPFixture()
    do {
      _ = try await KaibaAddonCatalog.executeForTesting(.init(workflowId: "fixture", stepId: "create", nodeId: "create",
        addon: .init(name: "kaiba/note-create", config: ["arguments": .object(["bodyMarkdown": .string("authored")])],
          inputs: ["bodyMarkdown": .string("override")])),
        client: fixtureKaibaClient(transport), environment: [:])
      XCTFail("ambiguous explicit inputs must not dispatch")
    } catch { XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked) }
    XCTAssertTrue(transport.requests.isEmpty)
  }

  func testRemoteGraphQLVariablesRemainLiteralInBothModes() async throws {
    for nested in [false, true] {
      let transport = KaibaHTTPFixture()
      let values: JSONObject = ["query": .string("query Fixture($text: String) { fixture(text: $text) }"),
                               "variables": .object(["text": .string("{{input.text}}")])]
      let config: JSONObject = nested ? ["arguments": .object(values)] : values
      _ = try await KaibaAddonCatalog.executeForTesting(.init(workflowId: "fixture", stepId: "read", nodeId: "read",
        addon: .init(name: "kaiba/note-graphql-document", config: config),
        variables: ["literal": .string("must-not-expand")], resolvedInputPayload: ["text": .string("{{literal}}")]),
        client: fixtureKaibaClient(transport), environment: [:])
      let request = try XCTUnwrap(transport.requests.first)
      let body = try JSONDecoder().decode(JSONObject.self, from: request.body)
      XCTAssertEqual(body["variables"], .object(["text": .string("{{literal}}")]))
    }
  }
}
