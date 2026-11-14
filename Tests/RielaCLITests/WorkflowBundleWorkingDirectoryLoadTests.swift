import Foundation
import RielaCore
import RielaWorkflowRegistry
import XCTest

final class WorkflowBundleWorkingDirectoryLoadTests: XCTestCase {
  func testLoadedDirectoriesAndCodableRoundTrip() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cwd-load-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    try #"""
    {"workflowId":"demo","defaults":{"maxLoopIterations":3,"nodeTimeoutMs":120000},"entryStepId":"step",
     "nodeRegistry":[{"id":"node","nodeFile":"nodes/node.json"}],
     "steps":[{"id":"step","nodeId":"node","role":"worker"}],
     "nodes":[{"id":"node","nodeFile":"nodes/node.json"}]}
    """#.write(to: root.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    for (directory, expected, authored) in [("sub", root.appendingPathComponent("sub").path, Optional("sub")),
                                            ("/absolute", "/absolute", nil), ("./sub", "./sub", nil)] {
      let json = #"{"id":"node","nodeType":"command","command":{"scriptPath":"scripts/run.sh","workingDirectory":"\#(directory)","authoredWorkingDirectory":"forged"}}"#
      try json.write(to: root.appendingPathComponent("nodes/node.json"), atomically: true, encoding: .utf8)
      let bundle = try WorkflowRegistryBundleLoader().loadBundle(at: root, rootDirectory: root.deletingLastPathComponent(), scope: .direct)
      let command = try XCTUnwrap(bundle.nodePayloads["node"]?.command)
      XCTAssertEqual(command.workingDirectory, expected)
      XCTAssertEqual(command.authoredWorkingDirectory, authored)
      XCTAssertEqual(command.executable, root.appendingPathComponent("scripts/run.sh").path)
      XCTAssertEqual(try JSONDecoder().decode(WorkflowCommandExecution.self, from: JSONEncoder().encode(command)), command)
    }
    try #"{"id":"node","nodeType":"container","container":{"image":"example","workingDirectory":"sub"}}"#
      .write(to: root.appendingPathComponent("nodes/node.json"), atomically: true, encoding: .utf8)
    let bundle = try WorkflowRegistryBundleLoader().loadBundle(at: root, rootDirectory: root.deletingLastPathComponent(), scope: .direct)
    let container = try XCTUnwrap(bundle.nodePayloads["node"]?.container)
    XCTAssertEqual(container.workingDirectory, root.appendingPathComponent("sub").path)
    XCTAssertEqual(container.authoredWorkingDirectory, "sub")
    XCTAssertEqual(try JSONDecoder().decode(WorkflowContainerExecution.self, from: JSONEncoder().encode(container)), container)
  }
}
