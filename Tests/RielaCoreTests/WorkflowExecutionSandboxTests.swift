import Foundation
import RielaCore
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
}
