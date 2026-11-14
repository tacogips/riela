import Foundation
import XCTest
@testable import RielaCore

final class WorkflowSandboxInstanceTests: XCTestCase {
  func testInstanceSandboxRoundTripPrecedenceAndAgentProjection() throws {
    let options = WorkflowExecutionSandbox(backend: .container, container: .init(image: "fixture:worker"),
      credentials: [.init(source: "/private/auth", homePath: ".vendor/auth")],
      admission: .init(directoryEnvironment: "RIELA_POOL", capacity: 4, weight: 2, minimumRemainingSeconds: 30))
    let patch = WorkflowInstanceNodePatch(sandbox: options)
    XCTAssertFalse(patch.isEmpty)
    XCTAssertEqual(try WorkflowInstanceNodePatch(jsonObject: patch.jsonObject, nodeId: "worker"), patch)
    XCTAssertEqual(try JSONDecoder().decode(WorkflowInstanceNodePatch.self, from: JSONEncoder().encode(patch)), patch)
    let override = WorkflowInstanceNodePatch(sandbox: .init(backend: .seatbelt))
    XCTAssertEqual(patch.merging(override).sandbox?.backend, .seatbelt)
    let projected = try WorkflowInstanceResolver.applyNodePatches(["worker": patch],
      to: ["worker": .init(id: "worker", executionBackend: .officialOpenAISDK, model: "fixture")])
    XCTAssertEqual(projected["worker"]?.sandbox, options)
  }

  func testMalformedSandboxPatchIsRejected() throws {
    XCTAssertThrowsError(try WorkflowInstanceNodePatch(jsonObject: ["sandbox": .string("seatbelt")], nodeId: "worker"))
    XCTAssertThrowsError(try WorkflowInstanceNodePatch(jsonObject: ["sandbox": .object(["backend": .string("unknown")])], nodeId: "worker"))
  }
}
