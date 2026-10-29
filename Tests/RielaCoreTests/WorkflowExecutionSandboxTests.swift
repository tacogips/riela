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

  func testContainerImageSpecificationRoundTripsWithoutChangingLegacyEqualityOrDigest() throws {
    let legacy = try JSONDecoder().decode(WorkflowAddonContainerExecution.self, from: Data(#"{"runtime":"auto","networkPolicy":"egress-allowed","mounts":[]}"#.utf8))
    let current = WorkflowAddonContainerExecution()
    XCTAssertEqual(current, legacy)
    XCTAssertNotEqual(current, WorkflowAddonContainerExecution(image: "custom:worker"))
    XCTAssertFalse(legacy.imageWasSpecified)

    let encoded = try JSONEncoder().encode(legacy)
    let roundTripped = try JSONDecoder().decode(WorkflowAddonContainerExecution.self, from: encoded)
    XCTAssertEqual(roundTripped, legacy)
    XCTAssertFalse(roundTripped.imageWasSpecified)

    let sandbox = WorkflowExecutionSandbox(backend: .container, container: legacy)
    let projected = try JSONDecoder().decode(WorkflowExecutionSandbox.self, from: JSONEncoder().encode(sandbox.jsonObject))
    XCTAssertEqual(projected, sandbox)
    XCTAssertFalse(try XCTUnwrap(projected.container).imageWasSpecified)

    let workflowWithoutContainerImage = WorkflowDefinition(workflowId: "legacy",
      defaults: .init(nodeTimeoutMs: 30_000, maxLoopIterations: 20), entryStepId: "start",
      nodeRegistry: [], steps: [], nodes: [])
    let digest = JSONCanonical.sha256Hex(try JSONCanonical.encode(workflowWithoutContainerImage))
    XCTAssertEqual(digest, "52f1666a94c1fd6d93059bbfb49d2490c6cd5cad18914094d59358a9069b8902")
  }
}
