import Foundation
import KaibaClient
import RielaCore
import XCTest
@testable import RielaKaibaAddons

final class KaibaWorkflowGatewayValidationTests: XCTestCase {
  func testNamedNestedArgumentsValidationMatchesRuntime() async throws {
    let name = "kaiba/note-create"
    let valid: JSONObject = ["arguments": .object(["bodyMarkdown": .string("checked")])]
    XCTAssertEqual(KaibaNestedArgumentRules.issues(addonName: name, config: valid, inputs: nil), [])

    let transport = KaibaHTTPFixture()
    _ = try await KaibaAddonCatalog.executeForTesting(
      input(name, config: valid), client: fixtureKaibaClient(transport), environment: [:]
    )
    XCTAssertEqual(transport.requests.count, 1)

    let invalidCases: [(JSONObject, JSONObject?)] = [
      (["arguments": .array([])], nil),
      (["arguments": .object(["bodyMarkdown": .string("x")]), "title": .string("mixed")], nil),
      (["arguments": .object(["bodyMarkdown": .string("x"), "endpoint": .string("https://invalid.example")])], nil),
      (["arguments": .object(["bodyMarkdown": .string("x")])], ["bodyMarkdown": .string("override")])
    ]
    for (config, inputs) in invalidCases {
      let errors = KaibaNestedArgumentRules.issues(addonName: name, config: config, inputs: inputs)
      XCTAssertFalse(errors.isEmpty)
      XCTAssertTrue(errors.allSatisfy { $0.relativePath.isEmpty })
      let failedTransport = KaibaHTTPFixture()
      do {
        _ = try await KaibaAddonCatalog.executeForTesting(
          input(name, config: config, inputs: inputs), client: fixtureKaibaClient(failedTransport), environment: [:]
        )
        XCTFail("invalid Kaiba arguments must fail before transport")
      } catch { XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked) }
      XCTAssertTrue(failedTransport.requests.isEmpty)
    }
  }

  func testGraphQLDocumentTemplateAndExactPlaceholderRulesMatchRuntime() async throws {
    let name = "kaiba/note-graphql-document"
    let templated: JSONObject = ["arguments": .object([
      "query": .string("{{input.query}}"), "variables": .object([:])
    ])]
    let errors = KaibaNestedArgumentRules.issues(addonName: name, config: templated, inputs: nil)
    XCTAssertEqual(errors.count, 1)
    XCTAssertTrue(errors[0].relativePath.isEmpty)
    let failedTransport = KaibaHTTPFixture()
    do {
      _ = try await KaibaAddonCatalog.executeForTesting(
        input(name, config: templated, resolved: ["query": .string("query Note { note { id } }")]),
        client: fixtureKaibaClient(failedTransport), environment: [:]
      )
      XCTFail("GraphQL structure must remain literal")
    } catch { XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked) }
    XCTAssertTrue(failedTransport.requests.isEmpty)

    let deferred: JSONObject = ["arguments": .string("{{input.arguments}}")]
    let createName = "kaiba/note-create"
    XCTAssertEqual(KaibaNestedArgumentRules.issues(addonName: createName, config: deferred, inputs: nil), [])
    let transport = KaibaHTTPFixture()
    _ = try await KaibaAddonCatalog.executeForTesting(
      input(createName, config: deferred, resolved: ["arguments": .object(["bodyMarkdown": .string("deferred")])]),
      client: fixtureKaibaClient(transport), environment: [:]
    )
    XCTAssertEqual(transport.requests.count, 1)
  }

  private func input(
    _ name: String,
    config: JSONObject,
    inputs: JSONObject? = nil,
    resolved: JSONObject = [:]
  ) -> WorkflowAddonExecutionInput {
    WorkflowAddonExecutionInput(workflowId: "kaiba-gateway-validation", stepId: "step", nodeId: "node",
      addon: .init(name: name, config: config, inputs: inputs), resolvedInputPayload: resolved)
  }

}
