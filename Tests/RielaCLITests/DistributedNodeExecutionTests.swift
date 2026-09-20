import Foundation
import RielaAdapters
@testable import RielaCore
@testable import RielaServer
import XCTest

final class DistributedNodeExecutionTests: XCTestCase {
  func testRemoteControllerOperationsAreDeniedEvenWhenExplicitlyAllowlisted() async throws {
    let names: Set<String> = ["riela/git-commit", "riela/git-push", "riela/workflow-create-register-run"]
    let resolver = DistributedFinalizationProbe()
    let executor = DistributedWorkerNodeExecutor(
      workspaces: ["project": .init(root: URL(fileURLWithPath: #filePath).deletingLastPathComponent())],
      adapter: DeterministicLocalNodeAdapter(), stdio: LocalWorkflowStdioNodeExecutor(), addons: resolver, allowedAddons: names
    )
    for name in names {
      let request = DistributedNodeRequest(invocation: .addon(.init(
        workflowId: "test", stepId: "work", nodeId: "node", addon: .init(name: name, version: "1")
      )), workspace: "project", timeoutSeconds: 5)
      let payload = try JSONDecoder().decode(JSONObject.self, from: JSONEncoder().encode(request))
      do {
        _ = try await executor.execute(.init(id: "test", target: .init(), payload: payload, status: .leased))
        XCTFail("Privileged finalization was executed on the worker")
      } catch let error as AdapterExecutionError { XCTAssertEqual(error.code, .policyBlocked) }
    }
    let calls = await resolver.calls
    XCTAssertEqual(calls, 0, "Reject before invoking a resolver, not after side effects")
  }

  func testWorkflowCommandExecutesInHTTPWorkersMappedWorkspace() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/distributed-workers/runtime-test/\(UUID().uuidString)")
    let workerRoot = root.appendingPathComponent("worker")
    try FileManager.default.createDirectory(at: workerRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let controller = try DistributedJobController(fileURL: root.appendingPathComponent("jobs.json"))
    let token = String(repeating: "r", count: 40)
    let router = try DistributedWorkerHTTPRouter(controller: controller, credentials: [.init(workerId: "remote", groups: ["linux"], token: token)])
    let server = RielaLocalHTTPServer(routeHandler: router)
    let port = try await server.startForTesting()
    let executor = DistributedWorkerNodeExecutor(
      workspaces: ["project": .init(root: workerRoot)], adapter: DeterministicLocalNodeAdapter(), stdio: LocalWorkflowStdioNodeExecutor()
    )
    let client = try DistributedWorkerHTTPClient(controllerURL: XCTUnwrap(URL(string: "http://127.0.0.1:\(port)")), token: token)
    let loop = try DistributedWorkerLoop(client: client, capacity: 1) { try await executor.execute($0) }
    let worker = Task { try await loop.run() }
    do {
      let workflow = WorkflowDefinition(
        workflowId: "remote-test", defaults: .init(nodeTimeoutMs: 10000, maxLoopIterations: 1), entryStepId: "work",
        nodeRegistry: [.init(id: "node", nodeFile: "node.json")],
        steps: [.init(id: "work", nodeId: "node", placement: .init(
          target: .init(workerId: "remote", group: "linux"), workspace: "project", exports: ["report.txt"]
        ))],
        nodes: [.init(id: "node", nodeFile: "node.json")]
      )
      let payload = AgentNodePayload(id: "node", nodeType: .command, model: "", command: .init(
        executable: "/bin/sh", arguments: ["-c", "touch executed; printf 'worker report' > report.txt; printf '{\"location\":\"remote\"}\\n'"]
      ))
      let runner = DeterministicWorkflowRunner(distributedExecutor: QueuedDistributedNodeExecutor(controller: controller))
      _ = try await runner.run(.init(workflow: workflow, nodePayloads: ["node": payload]))
      XCTAssertTrue(FileManager.default.fileExists(atPath: workerRoot.appendingPathComponent("executed").path))
      let jobs = try await controller.jobs(now: Date())
      let job = try XCTUnwrap(jobs.first)
      XCTAssertEqual(job.status, .succeeded)
      XCTAssertEqual(job.lease?.workerId, "remote")
      let result = try XCTUnwrap(job.result)
      let output = try JSONDecoder().decode(DistributedNodeOutput.self, from: JSONEncoder().encode(result.payload))
      guard case let .stdio(command) = output else { return XCTFail("wrong remote output type") }
      XCTAssertEqual(command.payload?["location"], .string("remote"))
      XCTAssertEqual(command.commandEvidence?.exitCode, 0)
      let artifacts = try await controller.artifacts(jobId: job.id)
      let artifact = try XCTUnwrap(artifacts.first)
      XCTAssertEqual(artifact.path, "report.txt")
      XCTAssertFalse(artifact.url.path.hasPrefix(workerRoot.path))
      XCTAssertEqual(try String(contentsOf: artifact.url, encoding: .utf8), "worker report")
    } catch {
      worker.cancel()
      _ = try? await worker.value
      await server.stop()
      throw error
    }
    worker.cancel()
    _ = try? await worker.value
    await server.stop()
  }

  func testExplicitPlacementDoesNotFallBackToLocalAdapter() async throws {
    let runner = DeterministicWorkflowRunner()
    let input = AdapterExecutionInput(node: .init(id: "node", model: "local"), promptText: "must not run")
    do {
      _ = try await runner.executePlacedAdapter(
        input, step: .init(id: "work", nodeId: "node", placement: .init(target: .init(workerId: "missing"), workspace: "project")),
        executionId: "attempt", context: .init()
      )
      XCTFail("Remote placement fell back to local")
    } catch let error as AdapterExecutionError { XCTAssertEqual(error.code, .providerError) }
  }

  func testWorkspaceMappingRejectsEscapes() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let workspace = DistributedWorkerWorkspace(root: root, controllerRoot: "/controller/project")
    XCTAssertEqual(try workspace.resolve("/controller/project/subdir"), root.appendingPathComponent("subdir").path)
    XCTAssertThrowsError(try workspace.resolve("../../outside"))
    XCTAssertThrowsError(try workspace.resolve("/controller/project-other"))
    XCTAssertThrowsError(try DistributedWorkerWorkspace(root: root).resolve("/etc"))
  }
}

private actor DistributedFinalizationProbe: WorkflowAddonResolving {
  var calls = 0
  func execute(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    calls += 1
    return .init(provider: "test", model: "test", promptText: "", completionPassed: true, payload: [:])
  }
}
