import Foundation
import RielaCore
import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import RielaAdapters

final class LocalProcessForegroundLifetimeTests: XCTestCase {
  func testNormalExitCleansBackgroundChildWithInheritedOutput() async throws {
    try await assertBackgroundChildIsReclaimed(redirectOutput: false)
  }

  func testNormalExitCleansBackgroundChildWithRedirectedOutput() async throws {
    try await assertBackgroundChildIsReclaimed(redirectOutput: true)
  }

  func testForegroundCommandRetainsTerminalStatusAndCompleteLogs() async throws {
    let output = try await FoundationLocalProcessRunner().run(
      configuration: .init(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: [
        "-c", "printf 'start\\n'; /bin/sleep 0.02; printf 'terminal stdout'; printf 'terminal stderr' >&2; exit 7"
      ]), stdin: "", deadline: Date().addingTimeInterval(5)
    )
    XCTAssertEqual(output.terminationStatus, 7)
    XCTAssertEqual(output.stdout, "start\nterminal stdout")
    XCTAssertEqual(output.stderr, "terminal stderr")
  }

  func testDeadlineDoesNotReturnBeforeIgnoringLeaderIsReclaimed() async throws {
    let processIdentity = ForegroundFixtureIdentity()
    let started = Date()
    do {
      _ = try await FoundationLocalProcessRunner().run(
        configuration: .init(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: [
          "-c", "trap '' TERM; printf '%s\\n' \"$$\"; /bin/sleep 4"
        ]), stdin: "", deadline: Date().addingTimeInterval(0.2),
        outputEventHandler: { processIdentity.record($0.line) }
      )
      XCTFail("Deadline must be returned as a timeout")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .timeout)
    }
    let processID = try XCTUnwrap(processIdentity.value)
    XCTAssertEqual(kill(processID, 0), -1, "A timeout result must not leave the ignored-TERM leader running")
    XCTAssertEqual(errno, ESRCH)
    XCTAssertLessThan(Date().timeIntervalSince(started), 3)
  }

  private func assertBackgroundChildIsReclaimed(redirectOutput: Bool) async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/specialist-supervisor/process-lifetime/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let childPIDFile = root.appendingPathComponent("child.pid")
    let releaseFile = root.appendingPathComponent("release")
    let effectFile = root.appendingPathComponent("unexpected-effect")
    defer {
      // The fixture also has its own finite iteration budget. A regression
      // cannot leave a permanent orphan, even when the assertion fails.
      try? Data().write(to: releaseFile)
      try? FileManager.default.removeItem(at: root)
    }
    let redirection = redirectOutput ? ">/dev/null 2>&1" : ""
    let script = """
    /bin/sh -c '
      trap "" TERM
      printf "%s" "$$" > "$1"
      count=0
      while [ ! -e "$2" ] && [ "$count" -lt 300 ]; do
        /bin/sleep 0.01
        count=$((count + 1))
      done
      if [ -e "$2" ]; then printf leaked > "$3"; fi
    ' child "\(childPIDFile.path)" "\(releaseFile.path)" "\(effectFile.path)" \(redirection) &
    count=0
    while [ ! -s "\(childPIDFile.path)" ] && [ "$count" -lt 200 ]; do
      /bin/sleep 0.01
      count=$((count + 1))
    done
    test -s "\(childPIDFile.path)" || exit 91
    printf 'leader-terminal\\n'
    """
    let started = Date()
    let result = try await FoundationLocalProcessRunner().run(
      configuration: .init(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script]),
      stdin: "", deadline: Date().addingTimeInterval(7)
    )
    XCTAssertLessThan(Date().timeIntervalSince(started), 2, "Leader exit must not wait for a background writer's natural EOF")
    XCTAssertEqual(result.terminationStatus, 0)
    XCTAssertEqual(result.stdout, "leader-terminal\n")
    let childPID = try XCTUnwrap(Int32(String(contentsOf: childPIDFile, encoding: .utf8)))
    let disappearanceDeadline = Date().addingTimeInterval(1)
    while kill(childPID, 0) == 0, Date() < disappearanceDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(kill(childPID, 0), -1, "Node return must not leave its background child running")
    XCTAssertEqual(errno, ESRCH)
    try Data().write(to: releaseFile)
    XCTAssertFalse(FileManager.default.fileExists(atPath: effectFile.path))
  }
}

private final class ForegroundFixtureIdentity: @unchecked Sendable {
  private let lock = NSLock()
  private var processID: Int32?
  var value: Int32? { lock.withLock { processID } }
  func record(_ line: String) { lock.withLock { processID = Int32(line) } }
}
