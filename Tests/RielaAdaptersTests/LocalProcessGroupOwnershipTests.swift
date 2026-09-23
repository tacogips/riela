import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import RielaAdapters

final class LocalProcessGroupOwnershipTests: XCTestCase {
  func testUnreapedLeaderPinsSignalAuthorityUntilReapAndClearsDelayedSignals() throws {
    let processId = try spawnExitedChild()
    defer { var status: Int32 = 0; _ = waitpid(processId, &status, WNOHANG) }
    let signals = RecordedGroupSignals()
    let handle = LocalProcessHandle(signalProcess: { signals.record($0, $1) })
    handle.store(processId: processId)
    XCTAssertTrue(handle.waitForLeaderExit())
    XCTAssertEqual(kill(processId, 0), 0, "WNOWAIT must retain the leader PID until signals finish")
    XCTAssertTrue(handle.terminateGroupOrProcess())
    XCTAssertTrue(handle.scheduleKillIfRunning(after: 0.02))
    XCTAssertEqual(handle.reapAfterOutput(terminateRemaining: false), 0)
    XCTAssertFalse(handle.killGroupOrProcess())
    XCTAssertFalse(handle.scheduleKillIfRunning(after: 0))
    Thread.sleep(forTimeInterval: 0.05)
    XCTAssertEqual(signals.values.map(\.target), [-processId])
    XCTAssertEqual(signals.values.map(\.signal), [SIGTERM], "Reaped IDs must never receive a delayed SIGKILL")
    XCTAssertEqual(kill(processId, 0), -1)
    XCTAssertEqual(errno, ESRCH)
  }

  func testExternallyReapedLeaderLosesAllSignalAuthority() throws {
    let processId = try spawnExitedChild()
    let signals = RecordedGroupSignals()
    let handle = LocalProcessHandle(signalProcess: { signals.record($0, $1) })
    handle.store(processId: processId)
    var status: Int32 = 0
    XCTAssertEqual(waitpid(processId, &status, 0), processId)
    XCTAssertFalse(handle.waitForLeaderExit())
    XCTAssertFalse(handle.terminateGroupOrProcess())
    XCTAssertFalse(handle.scheduleKillIfRunning(after: 0))
    XCTAssertTrue(signals.values.isEmpty)
  }

  private func spawnExitedChild() throws -> pid_t {
    guard let argument = strdup("/usr/bin/true") else { throw POSIXError(.ENOMEM) }
    defer { free(argument) }
    var arguments: [UnsafeMutablePointer<CChar>?] = [argument, nil]
    var processId: pid_t = 0
    let result = posix_spawn(&processId, "/usr/bin/true", nil, nil, &arguments, nil)
    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
    return processId
  }
}

private final class RecordedGroupSignals: @unchecked Sendable {
  struct Signal {
    let target: pid_t
    let signal: Int32
  }
  private let lock = NSLock()
  private var recorded: [Signal] = []
  var values: [Signal] { lock.withLock { recorded } }
  func record(_ target: pid_t, _ signal: Int32) -> Int32 {
    lock.withLock { recorded.append(Signal(target: target, signal: signal)) }
    return 0
  }
}
