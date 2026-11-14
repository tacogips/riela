import Foundation
import RielaAdapters
import RielaCore
import XCTest
@testable import RielaCLI
@testable import RielaServer

final class SandboxVendorSDKTests: XCTestCase {
  func testAllFourSDKsExecuteInNativeWorkerWithScopedHostCredentialsAndEvents() async throws {
    try XCTSkipUnless(RielaHostPlatform.current == .darwin, "native HTTP SDK worker gate")
    try await verifySDKs(containerImage: nil, providerHost: "127.0.0.1")
  }

  func testAllFourSDKsExecuteInContainerWorker() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let image = environment["RIELA_TEST_SANDBOX_CONTAINER_IMAGE"],
          let host = environment["RIELA_TEST_CONTAINER_HOST"],
          let proxyDirectory = environment["RIELA_TEST_SDK_PROXY_DIRECTORY"] else {
      throw XCTSkip("opt-in container image, host fixture address, and loopback proxy directory are required")
    }
    try await verifySDKs(containerImage: image, providerHost: host, proxyDirectory: proxyDirectory)
  }

  private func verifySDKs(containerImage: String?, providerHost: String, proxyDirectory: String? = nil) async throws {
    let root = try makeRielaCLITestTemporaryDirectory("sandbox-sdk-vendors")
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = root.appendingPathComponent("workspace")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
    let fixture = SandboxSDKHTTPFixture()
    let server = RielaLocalHTTPServer(routeHandler: fixture)
    let port = try await server.startForTesting(host: containerImage == nil ? "127.0.0.1" : "0.0.0.0")
    do {
      let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      let worker = repository.appendingPathComponent(".build/debug/riela").resolvingSymlinksInPath()
      let targets: [(NodeExecutionBackend, String)] = [(.officialOpenAISDK, "OPENAI_API_KEY"),
        (.officialAnthropicSDK, "ANTHROPIC_API_KEY"), (.officialGeminiSDK, "GEMINI_API_KEY"), (.officialCursorSDK, "CURSOR_API_KEY")]
      for (backend, key) in targets {
        let events = SDKWorkerEventStore()
        let adapter = SandboxingNodeAdapter(primary: SDKHostFallback(),
          environment: ["RIELA_SANDBOX_WORKER_EXECUTABLE": worker.path, "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", key: "fixture-only-key",
            "RIELA_FIXTURE_PROXY_HOST": providerHost, "RIELA_FIXTURE_PROXY_PORT": String(port)],
          workingDirectory: workspace.path, directoryParent: root)
        let node = AgentNodePayload(id: "sdk", executionBackend: backend, model: "fixture-model",
          sandbox: .init(backend: containerImage == nil ? .seatbelt : .container, networkPolicy: .egressAllowed,
            environment: containerImage == nil ? [key] : [key, "RIELA_FIXTURE_PROXY_HOST", "RIELA_FIXTURE_PROXY_PORT"],
            container: containerImage.map { .init(image: $0, runtime: .appleContainer,
              mounts: proxyDirectory.map { [.init(source: $0, target: "/opt/riela", readOnly: true)] } ?? []) }),
          baseURL: "http://127.0.0.1:\(port)/v1", apiKeyEnvironment: key)
        XCTAssertTrue(validateAgentNodePayload(node).filter { $0.severity == .error }.isEmpty, backend.rawValue)
        let output = try await adapter.execute(.init(node: node, promptText: "SDK fixture",
          executionIdentity: .init(workflowRunId: "sdk-run", workflowSessionId: "sdk-session", stepId: backend.rawValue)),
          context: .init(deadline: Date().addingTimeInterval(containerImage == nil ? 30 : 120), backendEventHandler: { event in await events.append(event) }))
        XCTAssertEqual(output.payload["text"], .string("sandbox-sdk-fixture"), backend.rawValue)
        let streamed = await events.values
        XCTAssertTrue(streamed.contains { $0.contentSnapshot == "sandbox-sdk-fixture" || $0.contentDelta == "sandbox-sdk-fixture" }, backend.rawValue)
        await adapter.workflowRunDidEnd(.init(workflowRunId: "sdk-run"))
      }
      let requests = await fixture.requests
      XCTAssertEqual(Set(requests.map(\.path)), ["/v1/responses", "/v1/messages", "/v1/models/fixture-model:streamGenerateContent", "/v1/agents"])
      XCTAssertEqual(requests.count, 4)
      for request in requests {
        switch request.path {
        case "/v1/messages": XCTAssertEqual(request.headers["x-api-key"], "fixture-only-key")
        case "/v1/models/fixture-model:streamGenerateContent": XCTAssertTrue(request.query?.contains("key=fixture-only-key") == true)
        case "/v1/agents": XCTAssertEqual(request.headers["authorization"], "Basic " + Data("fixture-only-key:".utf8).base64EncodedString())
        default: XCTAssertEqual(request.headers["authorization"], "Bearer fixture-only-key")
        }
      }
      await server.stop()
    } catch {
      await server.stop()
      throw error
    }
  }
}

private actor SandboxSDKHTTPFixture: RielaHTTPRouteHandling {
  var requests: [RielaHTTPRequest] = []

  func response(for request: RielaHTTPRequest) async -> RielaHTTPResponse {
    requests.append(request)
    if request.path == "/v1/agents" {
      return .json(.object(["id": .string("sdk-fixture-session"), "result": .string("sandbox-sdk-fixture")]))
    }
    let object: JSONObject
    switch request.path {
    case "/v1/responses":
      object = ["type": .string("response.output_text.delta"), "delta": .string("sandbox-sdk-fixture")]
    case "/v1/messages":
      object = ["type": .string("content_block_delta"), "delta": .object(["text": .string("sandbox-sdk-fixture")])]
    case "/v1/models/fixture-model:streamGenerateContent":
      object = ["candidates": .array([.object(["content": .object(["parts": .array([.object(["text": .string("sandbox-sdk-fixture")])])])])])]
    default: return .text(status: 404, "unexpected fixture route")
    }
    let data = (try? JSONEncoder().encode(object)) ?? Data()
    return .init(status: 200, headers: ["Content-Type": "text/event-stream"],
      body: Data("data: ".utf8) + data + Data("\n\n".utf8))
  }
}

private actor SDKWorkerEventStore {
  var values: [AdapterBackendEvent] = []
  func append(_ event: AdapterBackendEvent) { values.append(event) }
}

private struct SDKHostFallback: NodeAdapter {
  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    XCTFail("SDK node escaped its selected sandbox")
    throw AdapterExecutionError(.policyBlocked, "host fallback forbidden")
  }
}
