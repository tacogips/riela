import Foundation
import RielaCore
import XCTest
@testable import RielaCLI
#if os(Linux)
import Glibc
#else
import Darwin
#endif

final class SandboxExecutionAdmissionTests: XCTestCase {
  private let variable = "RIELA_TEST_MODEL_POOL"

  func testCapacityWeightAndEnvironmentAreValidated() async throws {
    let decoded = try JSONDecoder().decode(WorkflowExecutionAdmission.self,
      from: Data(#"{"directoryEnvironment":"MODEL_POOL","capacity":4}"#.utf8))
    XCTAssertEqual(decoded.weight, 1)
    XCTAssertEqual(decoded.waitTimeoutSeconds, 600)
    for policy in [WorkflowExecutionAdmission(directoryEnvironment: "bad-name", capacity: 4),
      .init(directoryEnvironment: variable, capacity: 0), .init(directoryEnvironment: variable, capacity: 65),
      .init(directoryEnvironment: variable, capacity: 4, weight: 5),
      .init(directoryEnvironment: variable, capacity: 4, waitTimeoutSeconds: 0)] {
      XCTAssertThrowsError(try policy.validate())
    }
    do {
      _ = try await SandboxExecutionAdmission.acquire(.init(directoryEnvironment: variable, capacity: 4),
        environment: [:], deadline: nil)
      XCTFail("missing host pool must not fall back")
    } catch let error as AdapterExecutionError { XCTAssertEqual(error.code, .policyBlocked) }
  }

  func testWeightedContentionReleasesPartialSlotsAndCancellationLeavesCapacityAvailable() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("admission-weight")
    defer { try? FileManager.default.removeItem(at: root) }
    let environment = [variable: root.path]
    let policy = WorkflowExecutionAdmission(directoryEnvironment: variable, capacity: 4)
    let one = try await SandboxExecutionAdmission.acquire(policy, environment: environment, deadline: nil)
    let variable = self.variable
    let waiter = Task {
      try await SandboxExecutionAdmission.acquire(.init(directoryEnvironment: variable, capacity: 4, weight: 4),
        environment: environment, deadline: Date().addingTimeInterval(5))
    }
    // A queued four-slot request must not strand the remaining three slots.
    try await Task.sleep(for: .milliseconds(75))
    let three = try await SandboxExecutionAdmission.acquire(.init(directoryEnvironment: variable, capacity: 4, weight: 3),
      environment: environment, deadline: Date().addingTimeInterval(1))
    waiter.cancel()
    do { _ = try await waiter.value; XCTFail("cancelled waiter acquired capacity") } catch is CancellationError {
      // No slot was transferred to the cancelled caller.
    } catch { XCTFail("unexpected cancellation error: \(error)") }
    withExtendedLifetime((one, three)) {}
  }

  func testLegacyProcessFlockBlocksNativeAdmissionAndExitReleasesLease() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("admission-legacy-process")
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("holder.py")
    let ready = root.appendingPathComponent("ready")
    try """
    import fcntl,pathlib,sys
    root=pathlib.Path(sys.argv[1])
    gate=(root/'admission.lock').open('a');fcntl.flock(gate,fcntl.LOCK_EX)
    slots=[(root/str(i)).open('a')for i in range(4)]
    for slot in slots:fcntl.flock(slot,fcntl.LOCK_EX)
    gate.close();(root/'ready').touch();sys.stdin.read()
    """.write(to: script, atomically: true, encoding: .utf8)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", script.path, root.path]
    let pipe = Pipe(); process.standardInput = pipe
    try process.run()
    defer {
      try? pipe.fileHandleForWriting.close()
      if process.isRunning { process.terminate() }
      process.waitUntilExit()
    }
    let readyDeadline = Date().addingTimeInterval(5)
    while !FileManager.default.fileExists(atPath: ready.path), process.isRunning, Date() < readyDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
    let policy = WorkflowExecutionAdmission(directoryEnvironment: variable, capacity: 4, weight: 4)
    do {
      _ = try await SandboxExecutionAdmission.acquire(policy, environment: [variable: root.path],
        deadline: Date().addingTimeInterval(0.1))
      XCTFail("native lease bypassed another process's locks")
    } catch let error as AdapterExecutionError { XCTAssertEqual(error.code, .timeout) }
    XCTAssertEqual(kill(process.processIdentifier, SIGKILL), 0)
    process.waitUntilExit()
    XCTAssertEqual(process.terminationReason, .uncaughtSignal)
    let lease = try await SandboxExecutionAdmission.acquire(policy, environment: [variable: root.path],
      deadline: Date().addingTimeInterval(1))
    XCTAssertNotNil(lease)
    withExtendedLifetime(lease) {}
  }

  func testPoolCapacityCannotChangeAndSymlinkedLocksAreRefused() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("admission-integrity")
    defer { try? FileManager.default.removeItem(at: root) }
    let policy = WorkflowExecutionAdmission(directoryEnvironment: variable, capacity: 4)
    var lease = try await SandboxExecutionAdmission.acquire(policy, environment: [variable: root.path], deadline: nil)
    XCTAssertNotNil(lease);lease = nil
    do {
      _ = try await SandboxExecutionAdmission.acquire(.init(directoryEnvironment: variable, capacity: 5),
        environment: [variable: root.path], deadline: nil)
      XCTFail("pool capacity changed")
    } catch let error as AdapterExecutionError { XCTAssertEqual(error.code, .policyBlocked) }
    let slot = root.appendingPathComponent("0")
    try FileManager.default.removeItem(at: slot)
    try FileManager.default.createSymbolicLink(atPath: slot.path, withDestinationPath: root.appendingPathComponent("capacity").path)
    do {
      _ = try await SandboxExecutionAdmission.acquire(policy, environment: [variable: root.path], deadline: nil)
      XCTFail("symlink slot admitted")
    } catch let error as AdapterExecutionError { XCTAssertEqual(error.code, .policyBlocked) }
  }
}
