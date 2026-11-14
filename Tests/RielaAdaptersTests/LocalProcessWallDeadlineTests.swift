import Foundation
import RielaCore
import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import RielaAdapters

final class LocalProcessWallDeadlineTests: XCTestCase {
  func testAbsoluteDeadlineTerminatesAndReapsProcess() async throws {
    let scheduler = RecordingProcessDeadlineScheduler()
    let identity = ProcessDeadlineIdentity()
    let deadline = Date().addingTimeInterval(3600)
    let task = Task {
      try await FoundationLocalProcessRunner(deadlineScheduler: scheduler).run(
        configuration: .init(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: [
          "-c", "printf '%s\\n' \"$$\"; exec /bin/sleep 30"
        ]), stdin: "", deadline: deadline, outputEventHandler: { identity.record($0.line) })
    }
    defer { task.cancel() }
    let limit = Date().addingTimeInterval(5)
    while scheduler.entry == nil || identity.value == nil {
      if Date() >= limit { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let entry = try XCTUnwrap(scheduler.entry)
    let pid = try XCTUnwrap(identity.value)
    XCTAssertEqual(entry.0, deadline)
    let started = Date()
    entry.1.perform()
    do {
      _ = try await task.value
      XCTFail("Expected timeout")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .timeout)
      XCTAssertEqual(error.message, "local agent process exceeded deadline and was terminated")
    }
    XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    XCTAssertEqual(kill(pid, 0), -1)
    XCTAssertEqual(errno, ESRCH)
  }

  func testCompletionCancelsDeadlineWorkItem() async throws {
    let scheduler = RecordingProcessDeadlineScheduler()
    let result = try await FoundationLocalProcessRunner(deadlineScheduler: scheduler).run(
      configuration: .init(executableURL: URL(fileURLWithPath: "/bin/echo"), arguments: ["hi"]),
      stdin: "", deadline: Date().addingTimeInterval(3600))
    XCTAssertEqual(result.stdout, "hi\n")
    XCTAssertTrue(try XCTUnwrap(scheduler.entry).1.isCancelled)
  }

  func testNoDeadlineDoesNotSchedule() async throws {
    let scheduler = RecordingProcessDeadlineScheduler()
    _ = try await FoundationLocalProcessRunner(deadlineScheduler: scheduler).run(
      configuration: .init(executableURL: URL(fileURLWithPath: "/bin/echo")), stdin: "")
    XCTAssertNil(scheduler.entry)
  }

  func testDefaultScheduler() {
    XCTAssertTrue(FoundationLocalProcessRunner().deadlineScheduler is SystemWallClockDeadlineScheduler)
  }
}

private final class RecordingProcessDeadlineScheduler: WallClockDeadlineScheduling, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: (Date, DispatchWorkItem)?
  var entry: (Date, DispatchWorkItem)? { lock.withLock { recorded } }
  func now() -> Date { Date() }
  func schedule(at deadline: Date, on queue: DispatchQueue, _ work: DispatchWorkItem) {
    lock.withLock { recorded = (deadline, work) }
  }
}

private final class ProcessDeadlineIdentity: @unchecked Sendable {
  private let lock = NSLock()
  private var pid: Int32?
  var value: Int32? { lock.withLock { pid } }
  func record(_ line: String) { lock.withLock { pid = Int32(line) } }
}
