import Foundation
import XCTest
@testable import RielaAdapters
import RielaCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class CommandExecutionLockTests: XCTestCase {
  func testSharedCoexistenceExclusiveConflictAndPartialAcquisitionRelease() throws {
    let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let first = try XCTUnwrap(acquire(root, [.init(name: "shared", mode: .shared)]))
    let second = try XCTUnwrap(acquire(root, [.init(name: "shared", mode: .shared)]))
    XCTAssertNil(try acquire(root, [.init(name: "shared")]))
    XCTAssertNil(try acquire(root, [.init(name: "free"), .init(name: "shared")]))
    let free = try XCTUnwrap(acquire(root, [.init(name: "free")])); free.release()
    first.release(); second.release()
    let exclusive = try XCTUnwrap(acquire(root, [.init(name: "shared")])); exclusive.release()
  }

  func testInvalidPolicyAndUnsafeLaterFileRefuseBeforeCreatingEarlierResource() throws {
    let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("bad").path, withDestinationPath: "absent")
    XCTAssertThrowsError(try acquire(root, [.init(name: "new"), .init(name: "bad")]))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("new").path))
    XCTAssertThrowsError(try acquire(root, [.init(name: "../escape")]))
    XCTAssertThrowsError(try acquire(root, [.init(name: "same"), .init(name: "same")]))
  }

  func testRelativeDefaultDirectoryIsScopedToCommandWorkingDirectory() throws {
    let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let policy = WorkflowCommandLocks(directoryEnvironment: "ABSENT", defaultDirectory: ".runtime/worker", resources: [.init(name: "run")])
    let lease = try XCTUnwrap(CommandExecutionLockLease.acquire(policy, environment: [:], workingDirectory: URL(fileURLWithPath: root.path, isDirectory: true)))
    defer { lease.release() }
    XCTAssertEqual(lease.directory, root.appendingPathComponent(".runtime/worker").resolvingSymlinksInPath().path)
  }

  func testBusyPayloadSkipsCommandAndInboundReceiptCannotBeSpoofed() async throws {
    let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let lease = try XCTUnwrap(acquire(root, [.init(name: "run")])); defer { lease.release() }
    var policy = policy(root); policy.busyPayload = ["busy": .bool(true)]
    let executor = LocalWorkflowStdioNodeExecutor(hostEnvironment: ["LOCK_ROOT": root.path, "RIELA_COMMAND_LOCKS": "forged"])
    let busy = try await executor.execute(input(.init(executable: "/must-not-spawn", executionLocks: policy)), context: .init())
    XCTAssertEqual(busy.payload, ["busy": .bool(true)])
    let clean = try await executor.execute(input(.init(executable: "/bin/sh", arguments: ["-c", "test -z \"$RIELA_COMMAND_LOCKS\" && printf '{\"clean\":true}'"],
      environment: ["RIELA_COMMAND_LOCKS": "also-forged"])), context: .init())
    XCTAssertEqual(clean.payload, ["clean": .bool(true)])
  }

  func testBusyDelegationRunsWithoutReceiptAndConflictingPolicyIsRejected() async throws {
    let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let lease = try XCTUnwrap(acquire(root, [.init(name: "run")])); defer { lease.release() }
    var policy = policy(root); policy.onBusy = .run
    let executor = LocalWorkflowStdioNodeExecutor(hostEnvironment: ["LOCK_ROOT": root.path, "RIELA_COMMAND_LOCKS": "forged"])
    let result = try await executor.execute(input(.init(executable: "/bin/sh", arguments: ["-c",
      "test -z \"$RIELA_COMMAND_LOCKS\" && printf '{\"delegated\":true}'"], executionLocks: policy)), context: .init())
    XCTAssertEqual(result.payload, ["delegated": .bool(true)])
    policy.busyPayload = ["busy": .bool(true)]
    XCTAssertThrowsError(try policy.validate())
  }

  func testRealChildRetainsLockWhenNativeOwnerClosesAndReleasesAtExit() async throws {
    let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let lease = try XCTUnwrap(acquire(root, [.init(name: "run")]))
    defer { lease.release() }
    let started = root.appendingPathComponent("started"), finish = root.appendingPathComponent("finish")
    let code = """
      import os,json,time,sys
      value=json.loads(os.environ['RIELA_COMMAND_LOCKS']);fd=value['resources'][0]['fd']
      os.fstat(fd);os.set_inheritable(fd,False)
      open(sys.argv[1],'w').close()
      for _ in range(500):
        if os.path.exists(sys.argv[2]):break
        time.sleep(.01)
      print(json.dumps({'inherited':True,'inheritable':os.get_inheritable(fd)}))
      """
    let config = LocalProcessConfiguration(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", code, started.path, finish.path],
      environment: [CommandExecutionLockLease.environmentKey: try lease.receipt()], inheritedDescriptors: lease.descriptors)
    let task = Task { try await FoundationLocalProcessRunner().run(configuration: config, stdin: "", deadline: Date().addingTimeInterval(8)) }
    do { try await waitFor(started) } catch {
      task.cancel(); let result = await task.result
      XCTFail("child startup result: \(result)"); throw error
    }
    lease.release()
    XCTAssertNil(try acquire(root, [.init(name: "run")]), "native owner close dropped the live child's lock")
    try Data().write(to: finish)
    let result = try await task.value
    XCTAssertEqual(result.terminationStatus, 0, result.stderr)
    XCTAssertTrue(result.stdout.contains("\"inherited\": true"))
    let next = try XCTUnwrap(acquire(root, [.init(name: "run")])); next.release()
  }

  func testCancellationHoldsAdmissionUntilOwnedCommandCleanupFinishes() async throws {
    let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let started = root.appendingPathComponent("started")
    let executor = LocalWorkflowStdioNodeExecutor(hostEnvironment: ["LOCK_ROOT": root.path])
    let command = WorkflowCommandExecution(executable: "/bin/sh", arguments: ["-c",
      "trap 'sleep .2; exit 143' TERM; touch \"$1\"; while :; do sleep 1; done", "fixture", started.path], executionLocks: policy(root))
    let request = input(command)
    let task = Task { try await executor.execute(request, context: .init(deadline: Date().addingTimeInterval(8))) }
    try await waitFor(started)
    task.cancel()
    XCTAssertNil(try acquire(root, [.init(name: "run")])); _ = await task.result
    let next = try XCTUnwrap(acquire(root, [.init(name: "run")])); next.release()
  }

  private func policy(_ root: URL) -> WorkflowCommandLocks {
    .init(directoryEnvironment: "LOCK_ROOT", resources: [.init(name: "run")])
  }
  private func acquire(_ root: URL, _ resources: [WorkflowCommandLocks.Resource]) throws -> CommandExecutionLockLease? {
    try CommandExecutionLockLease.acquire(.init(directoryEnvironment: "LOCK_ROOT", resources: resources), environment: ["LOCK_ROOT": root.path], workingDirectory: nil)
  }
  private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
  }
  private func waitFor(_ path: URL) async throws {
    for _ in 0..<300 {
      if FileManager.default.fileExists(atPath: path.path) { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw NSError(domain: "command child did not start", code: 1)
  }
  private func input(_ command: WorkflowCommandExecution) -> WorkflowStdioNodeExecutionInput {
    .init(workflowId: "locks", sessionId: "locks-session", stepId: "work", nodeId: "work", executionIndex: 1, kind: .command,
      node: .init(id: "work", nodeType: .command, model: "", command: command), variables: [:], resolvedInputPayload: [:])
  }
}
