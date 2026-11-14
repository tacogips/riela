import Foundation
@testable import RielaCore
import XCTest

final class WorkflowExecutionSandboxTests: XCTestCase {
  func testDefaultsAreStrictAndNodeAndAddonRoundTrip() throws {
    let defaults = try JSONDecoder().decode(WorkflowExecutionSandbox.self, from: Data("{}".utf8))
    XCTAssertEqual(defaults.backend, .auto)
    XCTAssertEqual(defaults.networkPolicy, .denied)
    XCTAssertEqual(defaults.environment, [])
    for backend in [WorkflowSandboxBackend.auto, .container, .seatbelt, .bubblewrap] {
      let settings = WorkflowExecutionSandbox(backend: backend, readPaths: ["/opt/tools"], credentialPaths: ["/host/auth"],
        environment: ["PROVIDER_KEY"], credentials: [.init(source: "/host/provider-auth", homePath: ".vendor/auth.json")])
      let node = AgentNodePayload(id: "vendor", executionBackend: .officialOpenAISDK, model: "fixture", sandbox: settings)
      XCTAssertEqual(try JSONDecoder().decode(AgentNodePayload.self, from: JSONEncoder().encode(node)), node)
      let addon = WorkflowNodeAddonRef(name: "riela/codex-sdk-worker", sandbox: settings)
      XCTAssertEqual(try JSONDecoder().decode(WorkflowNodeAddonRef.self, from: JSONEncoder().encode(addon)), addon)
    }
    let legacy = try JSONDecoder().decode(AgentNodePayload.self, from: Data(#"{"id":"legacy","model":"fixture"}"#.utf8))
    XCTAssertNil(legacy.sandbox)
  }

  func testInvalidModesAndBroadOrLoaderGrantsAreRejected() throws {
    for source in [
      #"{"backend":"unknown"}"#, #"{"readPaths":["/"]}"#, #"{"writePaths":["relative"]}"#,
      #"{"credentialPaths":["/host/auth\n"]}"#, #"{"environment":["DYLD_INSERT_LIBRARIES"]}"#,
      #"{"environment":["LD_PRELOAD"]}"#, #"{"environment":["HOME"]}"#,
      #"{"backend":"seatbelt","container":{}}"#,
      #"{"credentials":[{"source":"/host/auth","homePath":"../auth"}]}"#,
      #"{"credentials":[{"source":"/host/auth","homePath":"/absolute"}]}"#,
      #"{"credentials":[{"source":"/host/auth","homePath":".vendor"},{"source":"/host/other","homePath":".vendor/auth"}]}"#
    ] {
      XCTAssertThrowsError(try JSONDecoder().decode(WorkflowExecutionSandbox.self, from: Data(source.utf8)), source)
    }
  }

  func testContainerImageEncodingAndSandboxProjectionPreserveMainWireFormat() throws {
    let legacy = try JSONDecoder().decode(WorkflowAddonContainerExecution.self, from: Data(#"{"runtime":"auto","networkPolicy":"egress-allowed","mounts":[]}"#.utf8))
    let current = WorkflowAddonContainerExecution()
    XCTAssertEqual(current, legacy)
    XCTAssertNotEqual(current, WorkflowAddonContainerExecution(image: "custom:worker"))

    let encoded = try JSONEncoder().encode(legacy)
    let roundTripped = try JSONDecoder().decode(WorkflowAddonContainerExecution.self, from: encoded)
    XCTAssertEqual(roundTripped, legacy)

    let sandbox = WorkflowExecutionSandbox(backend: .container, container: legacy)
    let projected = try JSONDecoder().decode(WorkflowExecutionSandbox.self, from: JSONEncoder().encode(sandbox.jsonObject))
    XCTAssertEqual(projected, sandbox)
    XCTAssertEqual(try XCTUnwrap(projected.container).image, WorkflowAddonContainerExecution.defaultImage)

    let addonWorkflow = WorkflowDefinition(workflowId: "encoding-regression",
      defaults: .init(nodeTimeoutMs: 30_000, maxLoopIterations: 20), entryStepId: "start",
      nodeRegistry: [], steps: [], nodes: [.init(id: "media", addon: .init(name: "riela/media-download", container: .init()))])
    let sandboxWorkflow = WorkflowDefinition(workflowId: "encoding-regression",
      defaults: .init(nodeTimeoutMs: 30_000, maxLoopIterations: 20), entryStepId: "start",
      nodeRegistry: [], steps: [], nodes: [.init(id: "media", addon: .init(name: "riela/media-download",
        sandbox: .init(backend: .container, container: .init())))])
    let addonBytes = try JSONCanonical.encode(addonWorkflow)
    let sandboxBytes = try JSONCanonical.encode(sandboxWorkflow)
    let expectedAddonBytes = Data([
      #"{"defaults":{"maxLoopIterations":20,"nodeTimeoutMs":30000},"description":"","entryStepId":"start","nodeRegistry":[],"nodes":[{"addon":{"container":{"image":"riela-builtin-addons:local","mounts":[],"#,
      #""networkPolicy":"egress-allowed","runtime":"auto"},"name":"riela/media-download"},"id":"media"}],"steps":[],"workflowId":"encoding-regression"}"#
    ].joined().utf8)
    XCTAssertEqual(addonBytes, expectedAddonBytes)
    XCTAssertEqual(JSONCanonical.sha256Hex(addonBytes), "2c2f4724c062ff24f5b43dfa0c0884b22f37010fed0fe075b75bf933853ce24b")
    let expectedSandboxBytes = Data([
      #"{"defaults":{"maxLoopIterations":20,"nodeTimeoutMs":30000},"description":"","entryStepId":"start","nodeRegistry":[],"nodes":[{"addon":{"name":"riela/media-download","sandbox":{"#,
      #""backend":"container","container":{"#,
      #""image":"riela-builtin-addons:local","mounts":[],"networkPolicy":"egress-allowed","runtime":"auto"},"credentialEnvironment":{},"credentialPaths":[],"credentials":[],"environment":[],"ephemeralHome":false,"#,
      #""networkPolicy":"denied","readPaths":[],"writePaths":[]}},"id":"media"}],"steps":[],"workflowId":"encoding-regression"}"#
    ].joined().utf8)
    XCTAssertEqual(sandboxBytes, expectedSandboxBytes)
    XCTAssertEqual(JSONCanonical.sha256Hex(sandboxBytes), "ce8f2b2a7797a7b31b99a62712fcc81161de7374c2175fcfef00a3a8cafa0607")
  }
}
