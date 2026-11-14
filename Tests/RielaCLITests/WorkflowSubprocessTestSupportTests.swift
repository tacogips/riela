import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class WorkflowSubprocessTestSupportTests: XCTestCase {
  func testDefaultCaptureInheritsTheParentEnvironment() throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/specialist-supervisor/subprocess-environment/\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let result = try WorkflowSubprocessTestSupport.capture(executable: URL(fileURLWithPath: "/usr/bin/printenv"), arguments: ["PATH"], logRoot: root)
    XCTAssertEqual(result.status, 0)
    let expectedPath = try XCTUnwrap(ProcessInfo.processInfo.environment["PATH"])
    XCTAssertEqual(result.stdout.trimmingCharacters(in: .newlines), expectedPath)
  }

  func testCaptureAcceptsOutputLargerThanBothPipeBuffers() throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/specialist-supervisor/subprocess-capture/\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let result = try WorkflowSubprocessTestSupport.capture(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "head -c 262144 /dev/zero; head -c 262144 /dev/zero >&2"],
      logRoot: root
    )
    XCTAssertEqual(result.status, 0)
    XCTAssertEqual(result.stdout.utf8.count, 262_144)
    XCTAssertEqual(result.stderr.utf8.count, 262_144)
  }

  func testTimedOutOwnedProcessIsKilledAndReaped() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["30"]
    try process.run()
    XCTAssertThrowsError(try WorkflowSubprocessTestSupport.waitForExit(process, timeout: 0.02))
    XCTAssertFalse(process.isRunning)
    XCTAssertEqual(process.terminationReason, .uncaughtSignal)
    XCTAssertEqual(process.terminationStatus, SIGKILL)
    XCTAssertEqual(kill(process.processIdentifier, 0), -1)
    XCTAssertEqual(errno, ESRCH)
  }
}
