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
    XCTAssertEqual(decoded.minimumRemainingSeconds, 0)
    for policy in [WorkflowExecutionAdmission(directoryEnvironment: "bad-name", capacity: 4),
      .init(directoryEnvironment: variable, capacity: 0), .init(directoryEnvironment: variable, capacity: 65),
      .init(directoryEnvironment: variable, capacity: 4, weight: 5),
      .init(directoryEnvironment: variable, capacity: 4, waitTimeoutSeconds: 0),
      .init(directoryEnvironment: variable, capacity: 4, minimumRemainingSeconds: -1)] {
      XCTAssertThrowsError(try policy.validate())
    }
    do {
      _ = try await SandboxExecutionAdmission.acquire(.init(directoryEnvironment: variable, capacity: 4),
        environment: [:], deadline: nil)
      XCTFail("missing host pool must not fall back")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertEqual(error.message, SandboxExecutionAdmission.Refusal.missingEnvironment)
    }
  }

  func testInterruptedCapacityRecordIsRepairedInsteadOfPoisoningThePool() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("admission-capacity-repair")
    defer { try? FileManager.default.removeItem(at: root) }
    let capacity = root.appendingPathComponent("capacity")
    let policy = WorkflowExecutionAdmission(directoryEnvironment: variable, capacity: 12)
    // "1" and "12" are what a crash or short write of "12\n" can leave behind.
    for partial in ["", "1", "12"] {
      try Data(partial.utf8).write(to: capacity)
      var lease = try await SandboxExecutionAdmission.acquire(policy, environment: [variable: root.path], deadline: nil)
      XCTAssertNotNil(lease); lease = nil
      XCTAssertEqual(try String(contentsOf: capacity, encoding: .utf8), "12\n")
    }
    for (corrupt, message) in [("1x", SandboxExecutionAdmission.Refusal.capacityCorrupt),
      ("abc\n", SandboxExecutionAdmission.Refusal.capacityCorrupt),
      ("12\n3", SandboxExecutionAdmission.Refusal.capacityCorrupt),
      ("4\n", SandboxExecutionAdmission.Refusal.capacityMismatch)] {
      try Data(corrupt.utf8).write(to: capacity)
      do {
        _ = try await SandboxExecutionAdmission.acquire(policy, environment: [variable: root.path], deadline: nil)
        XCTFail("complete foreign record \(corrupt.debugDescription) was rewritten")
      } catch let error as AdapterExecutionError {
        XCTAssertEqual(error.code, .policyBlocked)
        XCTAssertEqual(error.message, message)
      }
      XCTAssertEqual(try String(contentsOf: capacity, encoding: .utf8), corrupt)
    }
  }

  func testRefusalCausesHaveDistinctPathFreeMessages() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("admission-refusals")
    defer { try? FileManager.default.removeItem(at: root) }
    let policy = WorkflowExecutionAdmission(directoryEnvironment: variable, capacity: 1)
    let cases: [([String: String], String)] = [
      ([:], SandboxExecutionAdmission.Refusal.missingEnvironment),
      ([variable: ""], SandboxExecutionAdmission.Refusal.missingEnvironment),
      ([variable: "relative/pool"], SandboxExecutionAdmission.Refusal.invalidPath),
      ([variable: "/"], SandboxExecutionAdmission.Refusal.invalidPath),
      ([variable: root.path + "/bad\u{1}name"], SandboxExecutionAdmission.Refusal.invalidPath)
    ]
    for (environment, message) in cases {
      do {
        _ = try await SandboxExecutionAdmission.acquire(policy, environment: environment, deadline: nil)
        XCTFail("refusal expected for \(environment)")
      } catch let error as AdapterExecutionError {
        XCTAssertEqual(error.code, .policyBlocked)
        XCTAssertEqual(error.message, message)
        XCTAssertFalse(error.message.contains(root.path))
      }
    }
    let file = root.appendingPathComponent("not-a-directory")
    try Data().write(to: file)
    do {
      _ = try await SandboxExecutionAdmission.acquire(policy, environment: [variable: file.path], deadline: nil)
      XCTFail("a regular file was accepted as the pool directory")
    } catch let error as AdapterExecutionError {
      XCTAssertTrue([SandboxExecutionAdmission.Refusal.createFailed, SandboxExecutionAdmission.Refusal.openFailed]
        .contains(error.message), error.message)
    }
    typealias Refusal = SandboxExecutionAdmission.Refusal
    let all = [Refusal.missingEnvironment, Refusal.invalidPath, Refusal.createFailed, Refusal.openFailed, Refusal.notOwned,
      Refusal.networkFilesystem, Refusal.lockFileSymlink, Refusal.lockFileOpen,
      Refusal.lockFileType, Refusal.lockFailed, Refusal.capacityRead, Refusal.capacityWrite, Refusal.capacityCorrupt,
      Refusal.capacityMismatch]
    XCTAssertEqual(Set(all).count, all.count)
  }

  func testNetworkFilesystemsAreRecognized() {
    for name in ["nfs", "nfs4", "cifs", "smb3", "smbfs", "afpfs", "webdav"] {
      XCTAssertTrue(SandboxExecutionAdmission.networkFilesystemTypes.contains(name), name)
    }
    for name in ["apfs", "hfs", "tmpfs", "ext4", "xfs", "btrfs", "overlay", "fuse.sshfs", "9p"] {
      XCTAssertFalse(SandboxExecutionAdmission.networkFilesystemTypes.contains(name), name)
    }
    let mountInfo = """
    22 1 8:1 / / rw,relatime shared:1 - ext4 /dev/sda1 rw
    30 22 0:40 / /mnt/shared rw,relatime shared:9 - nfs4 server:/export rw,vers=4.2
    31 30 0:41 / /mnt/shared/local\\040disk rw shared:10 - xfs /dev/sdb1 rw
    32 22 0:42 / /mnt/sharedness rw - tmpfs tmpfs rw
    """
    XCTAssertEqual(SandboxExecutionAdmission.filesystemType(forPath: "/var/pool", mountInfo: mountInfo), "ext4")
    XCTAssertEqual(SandboxExecutionAdmission.filesystemType(forPath: "/mnt/shared/pool", mountInfo: mountInfo), "nfs4")
    XCTAssertEqual(SandboxExecutionAdmission.filesystemType(forPath: "/mnt/shared", mountInfo: mountInfo), "nfs4")
    XCTAssertEqual(SandboxExecutionAdmission.filesystemType(forPath: "/mnt/shared/local disk/pool", mountInfo: mountInfo), "xfs")
    XCTAssertEqual(SandboxExecutionAdmission.filesystemType(forPath: "/mnt/sharedness/pool", mountInfo: mountInfo), "tmpfs")
    XCTAssertNil(SandboxExecutionAdmission.filesystemType(forPath: "/x", mountInfo: "garbage line"))
  }

  func testWithLeaseHoldsCapacityExactlyForTheBody() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("admission-with-lease")
    defer { try? FileManager.default.removeItem(at: root) }
    let environment = [variable: root.path]
    let policy = WorkflowExecutionAdmission(directoryEnvironment: variable, capacity: 1)
    let observed = try await SandboxExecutionAdmission.withLease(policy, environment: environment, deadline: nil) {
      do {
        _ = try await SandboxExecutionAdmission.acquire(policy, environment: environment,
          deadline: Date().addingTimeInterval(0.1))
        return "body ran without holding the lease"
      } catch let error as AdapterExecutionError {
        return error.code.rawValue
      }
    }
    XCTAssertEqual(observed, AdapterExecutionErrorCode.timeout.rawValue)
    let after = try await SandboxExecutionAdmission.acquire(policy, environment: environment,
      deadline: Date().addingTimeInterval(1))
    XCTAssertNotNil(after)
    withExtendedLifetime(after) {}
    let unadmitted = try await SandboxExecutionAdmission.withLease(nil, environment: [:], deadline: nil) { 7 }
    XCTAssertEqual(unadmitted, 7)
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
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertEqual(error.message, SandboxExecutionAdmission.Refusal.capacityMismatch)
    }
    let slot = root.appendingPathComponent("0")
    try FileManager.default.removeItem(at: slot)
    try FileManager.default.createSymbolicLink(atPath: slot.path, withDestinationPath: root.appendingPathComponent("capacity").path)
    do {
      _ = try await SandboxExecutionAdmission.acquire(policy, environment: [variable: root.path], deadline: nil)
      XCTFail("symlink slot admitted")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertEqual(error.message, SandboxExecutionAdmission.Refusal.lockFileSymlink)
    }
  }
}
