import Foundation
import RielaCore
import RielaKaibaAddons
import RielaKaibaSupport
import XCTest
@testable import RielaCLI
@testable import RielaServer

final class BuiltinSDKContainerIntegrationTests: XCTestCase {
  func testWorkflowCreationRegistrationAndExecutionRemainInsideGuest() async throws {
    let environment = ProcessInfo.processInfo.environment
    try XCTSkipUnless(environment["RIELA_TEST_LIVE_PROVIDER_IMAGE"] == "1", "opt-in test-only vendor fixture image")
    let root = try makeRielaCLITestTemporaryDirectory("generated-workflow-guest")
    defer { try? FileManager.default.removeItem(at: root) }
    let receipt = root.appendingPathComponent("vendor-cli.txt")
    let resolver = BuiltinAddonContainerResolver(transportRootDirectory: builtinContainerTransportRoot(for: root, testCase: self),
      primary: BuiltinWorkflowAddonResolver(environment: [:], workingDirectory: root),
      environment: ["CLI_RECEIPT": receipt.path], workingDirectory: root)
    let output = try await resolver.execute(.init(workflowId: "fixture", stepId: "generate", nodeId: "generate",
      addon: .init(name: "riela/workflow-create-register-run", version: "1", config: [
        "allowWorkflowCreation": .bool(true), "executionBackend": .string("codex-agent"), "model": .string("fixture-model")],
        env: ["RIELA_TEST_CLI_RECEIPT": .object(["fromEnv": .string("CLI_RECEIPT")])],
        container: .init(image: environment["RIELA_TEST_PROVIDER_IMAGE"] ?? "riela-provider-fixture:local",
          runtime: .appleContainer, networkPolicy: .denied)),
      resolvedInputPayload: ["run_workflow": .bool(true), "llm_only": .bool(false),
        "workflowTask": .object(["title": .string("Fixture task"), "prompt": .string("Respond to the fixture")])]),
      context: .init(deadline: Date().addingTimeInterval(180)))
    XCTAssertEqual(output.payload["generatedWorkflowRegistered"], .bool(true))
    XCTAssertEqual(output.payload["generatedWorkflowExecuted"], .bool(true))
    guard case let .string(sessionId)? = output.payload["generatedWorkflowSessionId"] else { return XCTFail("runtime session is missing") }
    XCTAssertFalse(sessionId.isEmpty)
    XCTAssertNotEqual(sessionId, "fixture-vendor-thread")
    XCTAssertTrue(try String(contentsOf: receipt, encoding: .utf8).contains("exec --json"))
  }

  func testCapturedKaibaInstanceReplacesGuestCatalog() async throws {
    let environment = ProcessInfo.processInfo.environment
    try XCTSkipUnless(environment["RIELA_TEST_LIVE_BUILTIN_IMAGE"] == "1", "opt-in real guest Kaiba test")
    let root = try makeRielaCLITestTemporaryDirectory("guest-kaiba-instance")
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = KaibaHostLoopbackFixture()
    let server = RielaLocalHTTPServer(routeHandler: fixture)
    let port = try await server.startForTesting()
    let runtimeEnvironment = ["KAIBA_TOKEN": "host-fixture-key"]
    let instance = KaibaInstance(id: UUID().uuidString.lowercased(), name: "Captured instance",
      endpoint: "http://127.0.0.1:\(port)/graphql", authentication: .bearer(environmentVariable: "KAIBA_TOKEN"), isDefault: true)
    let snapshot = try KaibaExecutionSnapshot(bindingIDs: [nil], catalog: .init(instances: [instance]), environment: runtimeEnvironment)
    let resolver = BuiltinAddonContainerResolver(transportRootDirectory: builtinContainerTransportRoot(for: root, testCase: self), primary: BuiltinWorkflowAddonResolver(environment: [:], workingDirectory: root),
      environment: runtimeEnvironment, workingDirectory: root)
    do {
      let output = try await KaibaAddonExecutionContext.withSnapshot(snapshot, allowsMockExecution: false) {
        try await resolver.execute(.init(workflowId: "fixture", stepId: "kaiba", nodeId: "kaiba",
          addon: .init(name: "kaiba/note-graphql-document", version: "1", config: ["query": .string("query { fixture }")],
            container: .init(image: environment["RIELA_TEST_BUILTIN_IMAGE"] ?? WorkflowAddonContainerExecution.defaultImage,
              runtime: .appleContainer, networkPolicy: .denied))), context: .init(deadline: Date().addingTimeInterval(120)))
      }
      XCTAssertEqual(output.payload["fieldPayload"], .string("guest-kaiba"))
      let requests = await fixture.requests
      XCTAssertEqual(requests.count, 2, "guest readiness and business query must both execute")
      XCTAssertTrue(requests.allSatisfy { $0.headers["authorization"] == "Bearer host-fixture-key" })
      await server.stop()
    } catch {
      await server.stop()
      throw error
    }
  }

  func testAllSwiftSDKWorkersExecuteAgainstGuestLoopbackProviderWithoutNetwork() async throws {
    let environment = ProcessInfo.processInfo.environment
    try XCTSkipUnless(environment["RIELA_TEST_LIVE_PROVIDER_IMAGE"] == "1", "opt-in test-only provider fixture image")
    let root = try makeRielaCLITestTemporaryDirectory("guest-sdk-provider")
    defer { try? FileManager.default.removeItem(at: root) }
    let receipt = root.appendingPathComponent("requests.txt")
    let resolver = BuiltinAddonContainerResolver(transportRootDirectory: builtinContainerTransportRoot(for: root, testCase: self), primary: BuiltinWorkflowAddonResolver(environment: [:], workingDirectory: root),
      environment: ["FIXTURE_KEY": "fixture-key", "FIXTURE_RECEIPT": receipt.path], workingDirectory: root)
    let targets = ["riela/codex-sdk-worker": "OPENAI_API_KEY", "riela/claude-sdk-worker": "ANTHROPIC_API_KEY",
      "riela/gemini-sdk-worker": "GEMINI_API_KEY", "riela/cursor-sdk-worker": "CURSOR_API_KEY"]
    for name in targets.keys.sorted() {
      let target = try XCTUnwrap(targets[name])
      let output = try await resolver.execute(.init(workflowId: "fixture", stepId: "sdk", nodeId: "sdk",
        addon: .init(name: name, version: "1", config: ["model": .string("fixture-model"),
          "promptTemplate": .string("fixture request"), "baseURL": .string("http://127.0.0.1:31821/v1")],
          env: [target: .object(["fromEnv": .string("FIXTURE_KEY")]),
            "RIELA_TEST_PROVIDER_RECEIPT": .object(["fromEnv": .string("FIXTURE_RECEIPT")])],
          container: .init(image: environment["RIELA_TEST_PROVIDER_IMAGE"] ?? "riela-provider-fixture:local",
            runtime: .appleContainer, networkPolicy: .denied))), context: .init(deadline: Date().addingTimeInterval(120)))
      XCTAssertEqual(output.payload["text"], .string("container-fixture"), name)
      XCTAssertTrue(output.completionPassed, name)
    }
    let requests = try String(contentsOf: receipt, encoding: .utf8).components(separatedBy: .newlines)
    for route in ["POST /v1/responses", "POST /v1/messages", "POST /v1/models/fixture-model:streamGenerateContent", "POST /v1/agents"] {
      XCTAssertTrue(requests.contains(route), "missing guest request: \(route)")
    }
  }
}

private actor KaibaHostLoopbackFixture: RielaHTTPRouteHandling {
  var requests: [RielaHTTPRequest] = []

  func response(for request: RielaHTTPRequest) async -> RielaHTTPResponse {
    requests.append(request)
    if case let .object(body)? = try? JSONDecoder().decode(JSONValue.self, from: request.body),
       case let .string(query)? = body["query"], query.contains("KaibaClientReadiness") {
      return .json(.object(["data": .object(["kaibaReadiness": .object([
        "result": .object(["accepted": .bool(true), "status": .string("ok")])])])]))
    }
    return .json(.object(["data": .object(["fixture": .string("guest-kaiba")])]))
  }
}
