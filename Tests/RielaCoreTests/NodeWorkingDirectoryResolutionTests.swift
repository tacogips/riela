import Foundation
import XCTest
@testable import RielaCore

final class NodeWorkingDirectoryResolutionTests: XCTestCase {
  private var root: URL { FileManager.default.temporaryDirectory.appendingPathComponent("riela-node-cwd-test") }

  func testAgentDirectoriesAndRecords() async throws {
    for (path, expected) in [("sub/dir", "sub/dir"), ("a/../b", "b"), ("/abs/../path", "/abs/../path")] {
      let adapter = CwdRecordingAdapter()
      let result = try await DeterministicWorkflowRunner(adapter: adapter, fanoutWorkspaceRoot: root).run(
        DeterministicWorkflowRunRequest(workflow: workflow(), nodePayloads: ["node": agent(path)])
      )
      let captured = await adapter.directory()
      let dispatched = path.hasPrefix("/") ? expected : root.appendingPathComponent(expected).standardizedFileURL.path
      XCTAssertEqual(captured, dispatched)
      XCTAssertEqual(result.session.executions.first?.backendWorkingDirectory, URL(fileURLWithPath: dispatched).standardizedFileURL.path)
    }
    let adapter = CwdRecordingAdapter()
    let result = try await DeterministicWorkflowRunner(adapter: adapter, fanoutWorkspaceRoot: root).run(
      DeterministicWorkflowRunRequest(workflow: workflow(), nodePayloads: ["node": agent(nil)])
    )
    let captured = await adapter.directory()
    XCTAssertNil(captured)
    XCTAssertEqual(result.session.executions.first?.backendWorkingDirectory, root.standardizedFileURL.path)
    XCTAssertEqual(anchoredWorkingDirectory("rel", workspaceRoot: nil), "rel")
  }

  func testStdioDirectories() async throws {
    let executor = StaticStdioNodeExecutor()
    let runner = DeterministicWorkflowRunner(stdioNodeExecutor: executor, fanoutWorkspaceRoot: root)
    let payloads = [
      AgentNodePayload(id: "node", nodeType: .command, model: "", workingDirectory: "w",
                       command: WorkflowCommandExecution(executable: "/bin/sh")),
      AgentNodePayload(id: "node", nodeType: .command, model: "",
                       command: WorkflowCommandExecution(executable: "/bin/sh", workingDirectory: "c")),
      AgentNodePayload(id: "node", nodeType: .container, model: "",
                       container: WorkflowContainerExecution(image: "example/image", workingDirectory: "k")),
      AgentNodePayload(id: "node", nodeType: .container, model: "",
                       container: WorkflowContainerExecution(image: "example/image", workingDirectory: "/bundle/sub",
                                                             authoredWorkingDirectory: "sub"))
    ]
    var records: [String?] = []
    for payload in payloads {
      let result = try await runner.run(DeterministicWorkflowRunRequest(workflow: workflow(), nodePayloads: ["node": payload]))
      records.append(result.session.executions.first?.backendWorkingDirectory)
    }
    XCTAssertEqual(records, ["w", "c", "k", "sub"].map { root.appendingPathComponent($0).standardizedFileURL.path })
    let inputs = await executor.capturedInputs()
    XCTAssertEqual(inputs.count, 4)
    XCTAssertEqual(inputs[0].node.workingDirectory, root.appendingPathComponent("w").path)
    XCTAssertNil(inputs[0].node.command?.workingDirectory)
    XCTAssertEqual(inputs[1].node.command?.workingDirectory, root.appendingPathComponent("c").path)
    XCTAssertEqual(inputs[2].node.container?.workingDirectory, root.appendingPathComponent("k").path)
    XCTAssertEqual(inputs[3].node.container?.workingDirectory, root.appendingPathComponent("sub").path)
    XCTAssertNil(inputs[3].node.container?.authoredWorkingDirectory)
  }

  func testPlacementPreservesRelativeDirectory() async throws {
    let executor = CwdDistributedRecorder()
    _ = try await DeterministicWorkflowRunner(distributedExecutor: executor, fanoutWorkspaceRoot: root).run(
      DeterministicWorkflowRunRequest(workflow: workflow(placed: true), nodePayloads: ["node": agent("sub/dir")])
    )
    let captured = await executor.directory()
    XCTAssertEqual(captured, "sub/dir")
  }

  func testAuthoredDirectoriesAndSharedPlacement() async throws {
    let local = StaticStdioNodeExecutor(result: WorkflowStdioNodeExecutionResult(payload: ["status": .string("ok")]))
    let remote = CwdDistributedRecorder()
    let original = "/controller/workflows/demo/sub"
    let command = WorkflowCommandExecution(executable: "/bin/sh", workingDirectory: original, authoredWorkingDirectory: "sub")
    let payload = AgentNodePayload(id: "node", nodeType: .command, model: "", command: command)
    let definition = WorkflowDefinition(
      workflowId: "shared", defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3), entryStepId: "local",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json")],
      steps: [WorkflowStepRef(id: "local", nodeId: "node", transitions: [WorkflowStepTransition(toStepId: "remote")]),
              WorkflowStepRef(id: "remote", nodeId: "node", placement: DistributedExecutionPlacement(
                target: DistributedWorkerTarget(), workspace: "remote"))],
      nodes: [WorkflowNodeRef(id: "local", nodeFile: "nodes/node.json"),
              WorkflowNodeRef(id: "remote", nodeFile: "nodes/node.json")]
    )
    _ = try await DeterministicWorkflowRunner(distributedExecutor: remote, stdioNodeExecutor: local, fanoutWorkspaceRoot: root)
      .run(DeterministicWorkflowRunRequest(workflow: definition, nodePayloads: ["node": payload]))
    let localInput = await local.capturedInputs().first
    let remoteNode = await remote.node()
    XCTAssertEqual(localInput?.node.command?.workingDirectory, root.appendingPathComponent("sub").path)
    XCTAssertNil(localInput?.node.command?.authoredWorkingDirectory)
    XCTAssertEqual(remoteNode?.command?.workingDirectory, original)
    XCTAssertEqual(remoteNode?.command?.authoredWorkingDirectory, "sub")
    let container = AgentNodePayload(id: "node", nodeType: .container, model: "", container:
      WorkflowContainerExecution(image: "image", workingDirectory: original, authoredWorkingDirectory: "sub"))
    let anchored = anchoringLocalWorkingDirectories(container, workspaceRoot: root)
    XCTAssertEqual(anchored.container?.workingDirectory, root.appendingPathComponent("sub").path)
    XCTAssertNil(anchored.container?.authoredWorkingDirectory)
    XCTAssertEqual(anchoringLocalWorkingDirectories(payload, workspaceRoot: nil).command?.workingDirectory, original)
    let mapped = DistributedWorkerWorkspace(root: URL(fileURLWithPath: "/worker"), controllerRoot: "/controller")
    XCTAssertEqual(try mapped.resolve(original), "/worker/workflows/demo/sub")
    XCTAssertThrowsError(try DistributedWorkerWorkspace(root: URL(fileURLWithPath: "/worker")).resolve(original)) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidInput)
    }
  }

  private func agent(_ path: String?) -> AgentNodePayload {
    AgentNodePayload(id: "node", executionBackend: .codexAgent, model: "test", workingDirectory: path, agentSandbox: .readOnly)
  }

  private func workflow(placed: Bool = false) -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "runner", defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3), entryStepId: "step",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json")],
      steps: [WorkflowStepRef(id: "step", nodeId: "node", placement: placed
        ? DistributedExecutionPlacement(target: DistributedWorkerTarget(), workspace: "remote") : nil)],
      nodes: [WorkflowNodeRef(id: "step", nodeFile: "nodes/node.json")]
    )
  }
}

private actor CwdRecordingAdapter: NodeAdapter {
  private var path: String?
  func directory() -> String? { path }
  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    path = input.node.workingDirectory
    return AdapterExecutionOutput(provider: "test", model: input.node.model, promptText: input.promptText,
                                  completionPassed: true, payload: [:])
  }
}

private actor CwdDistributedRecorder: DistributedNodeExecuting {
  private var path: String?
  private var capturedNode: AgentNodePayload?
  func directory() -> String? { path }
  func node() -> AgentNodePayload? { capturedNode }
  func execute(_ invocation: DistributedNodeInvocation, executionId: String, placement: DistributedExecutionPlacement,
               context: AdapterExecutionContext) async throws -> DistributedNodeOutput {
    if case let .stdio(input) = invocation {
      capturedNode = input.node
      return .stdio(WorkflowStdioNodeExecutionResult(payload: nil))
    }
    guard case let .adapter(input) = invocation else { throw AdapterExecutionError(.providerError, "unexpected invocation") }
    path = input.node.workingDirectory
    return .adapter(AdapterExecutionOutput(provider: "test", model: input.node.model, promptText: input.promptText,
                                           completionPassed: true, payload: [:]))
  }
}
