import Foundation
import RielaAdapters
import RielaCore
@testable import RielaServer
import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class DistributedProcessCancellationTests: XCTestCase {
  func testControllerCancellationStopsProcessTreeAndKeepsWorkerAvailable() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/distributed-workers/cancellation/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let controller = try DistributedJobController(fileURL: root.appendingPathComponent("jobs.json"))
    let token = String(repeating: "c", count: 40)
    let router = try DistributedWorkerHTTPRouter(
      controller: controller, credentials: [.init(workerId: "worker", groups: [], token: token)], leaseDurationSeconds: 3
    )
    let server = RielaLocalHTTPServer(routeHandler: router)
    let port = try await server.startForTesting()
    let client = try DistributedWorkerHTTPClient(controllerURL: XCTUnwrap(URL(string: "http://127.0.0.1:\(port)")), token: token)
    let executor = DistributedWorkerNodeExecutor(
      workspaces: ["project": .init(root: root)], adapter: DeterministicLocalNodeAdapter(), stdio: LocalWorkflowStdioNodeExecutor()
    )
    let loop = try DistributedWorkerLoop(client: client, capacity: 1) { try await executor.execute($0) }
    let worker = Task { try await loop.run() }
    addTeardownBlock {
      worker.cancel()
      _ = try? await worker.value
      await server.stop()
      try? FileManager.default.removeItem(at: root)
    }
    // Both processes ignore TERM. Finite sleeps bound fixture lifetime even
    // if process-group cancellation regresses. All paths are workspace-local.
    let script = """
    trap '' TERM
    printf '%s' "$$" > leader.pid
    /bin/sh -c 'trap "" TERM; printf "%s" "$$" > child.pid; /bin/sleep 20' &
    wait
    """
    _ = try await controller.enqueue(id: "cancel", target: .init(), payload: try payload(script: script))
    let readyDeadline = Date().addingTimeInterval(5)
    let childFile = root.appendingPathComponent("child.pid")
    while !FileManager.default.fileExists(atPath: childFile.path), Date() < readyDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    let leader = try XCTUnwrap(Int32(String(contentsOf: root.appendingPathComponent("leader.pid"), encoding: .utf8)))
    let child = try XCTUnwrap(Int32(String(contentsOf: childFile, encoding: .utf8)))
    XCTAssertTrue(isExecuting(leader))
    XCTAssertTrue(isExecuting(child))
    try await controller.cancel(jobId: "cancel")
    _ = try await controller.enqueue(id: "next", target: .init(), payload: try payload(script: "printf '{\"ok\":true}\\n'"))
    let deadline = Date().addingTimeInterval(8)
    var completed = false
    while Date() < deadline {
      let jobs = try await controller.jobs(now: Date())
      completed = jobs.contains { $0.id == "next" && $0.status == .succeeded }
      if jobs.first(where: { $0.id == "cancel" })?.stoppedAt != nil {
        XCTAssertFalse(isExecuting(leader), "Stop receipt preceded leader termination")
        XCTAssertFalse(isExecuting(child), "Stop receipt preceded child termination")
      }
      if completed && !isExecuting(leader) && !isExecuting(child) { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertFalse(isExecuting(leader), "Cancelled remote shell must stop before the lane accepts new work")
    XCTAssertFalse(isExecuting(child), "Cancelled remote shell must not leave executing descendants")
    XCTAssertTrue(completed, "Cancelling a job must leave its worker available for subsequent work")
    let cancelled = try await controller.jobs(now: Date()).first { $0.id == "cancel" }
    XCTAssertEqual(cancelled?.status, .cancelled)
    XCTAssertNotNil(cancelled?.stoppedAt, "Cancelled claimed work needs a durable worker-stop receipt")
    XCTAssertNil(cancelled?.result, "Cancelled work must not publish a late result")
  }

  private func payload(script: String) throws -> JSONObject {
    let invocation = WorkflowStdioNodeExecutionInput(
      workflowId: "test", sessionId: "test", stepId: "step", nodeId: "node", executionIndex: 1, kind: .command,
      node: .init(id: "node", nodeType: .command, model: "", command: .init(executable: "/bin/sh", arguments: ["-c", script])),
      variables: [:], resolvedInputPayload: [:]
    )
    let request = DistributedNodeRequest(invocation: .stdio(invocation), workspace: "project", timeoutSeconds: 30)
    return try JSONDecoder().decode(JSONObject.self, from: JSONEncoder().encode(request))
  }

  private func isExecuting(_ processID: Int32) -> Bool {
    guard kill(processID, 0) == 0 else { return false }
    #if os(Linux)
    // Minimal container PID 1 may retain a reparented zombie. It cannot execute
    // or perform side effects; distinguish this from a live leaked descendant.
    if let status = try? String(contentsOfFile: "/proc/\(processID)/stat", encoding: .utf8),
      let end = status.lastIndex(of: ")"), status[status.index(after: end)...].hasPrefix(" Z ") { return false }
    #endif
    return true
  }
}
