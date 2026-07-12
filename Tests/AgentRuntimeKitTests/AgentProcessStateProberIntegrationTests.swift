import Foundation
import XCTest
@testable import AgentRuntimeKit
#if canImport(Glibc)
import Glibc
#endif

/// Real-process regressions for the probing layer on macOS and Linux: a
/// spawned child that exits without being reaped is observed as a zombie
/// with our pid as parent and a stable start identity; reaping flips it to
/// missing. This is the process-observation half of the post-summary
/// unreaped-child shape (the classification/cleanup half is deterministic in
/// `CodexToolChildRecoveryTests`).
final class AgentProcessStateProberIntegrationTests: XCTestCase {
  func testProberObservesRealZombieChildAndItsReaping() throws {
    var childPid = pid_t()
    let argv = CStringArrayFixture(["/usr/bin/true"])
    let spawnResult = argv.withUnsafeMutableBufferPointer { pointer in
      posix_spawn(&childPid, "/usr/bin/true", nil, nil, pointer.baseAddress, nil)
    }
    guard spawnResult == 0 else {
      throw XCTSkip("posix_spawn unavailable in this environment (\(spawnResult))")
    }
    defer {
      var status: Int32 = 0
      _ = waitpid(childPid, &status, WNOHANG)
    }

    let prober = SystemAgentProcessStateProber()
    // The child exits immediately; without a waitpid it must become a zombie.
    var probed = prober.probe(processId: Int32(childPid))
    let deadline = Date().addingTimeInterval(5)
    while probed.state != .zombie, Date() < deadline {
      usleep(20_000)
      probed = prober.probe(processId: Int32(childPid))
    }
    XCTAssertEqual(probed.state, .zombie, "an exited, unreaped child is observed as a zombie")
    XCTAssertEqual(probed.parentProcessId, getpid(), "the zombie is parented to its spawner")
    XCTAssertNotNil(probed.startIdentity, "start identity guards against PID reuse")

    // Our own process reads as running.
    XCTAssertEqual(prober.probe(processId: getpid()).state, .running)

    // Reaping the child removes it from observation.
    var status: Int32 = 0
    XCTAssertEqual(waitpid(childPid, &status, 0), childPid)
    XCTAssertEqual(prober.probe(processId: Int32(childPid)).state, .missing)
  }

  func testChildDiscovererFindsSpawnedChild() throws {
    // A long-lived real child is discoverable via the parent pid.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["5"]
    try process.run()
    defer {
      process.terminate()
      process.waitUntilExit()
    }
    let children = SystemAgentChildProcessDiscoverer().childProcessIds(of: getpid())
    XCTAssertTrue(
      children.contains(Int32(process.processIdentifier)),
      "spawned child \(process.processIdentifier) not in \(children)"
    )
  }
}

private final class CStringArrayFixture {
  private var pointers: [UnsafeMutablePointer<CChar>?]

  init(_ strings: [String]) {
    pointers = strings.map { strdup($0) } + [nil]
  }

  deinit {
    for pointer in pointers {
      free(pointer)
    }
  }

  func withUnsafeMutableBufferPointer<Result>(
    _ body: (inout UnsafeMutableBufferPointer<UnsafeMutablePointer<CChar>?>) -> Result
  ) -> Result {
    pointers.withUnsafeMutableBufferPointer { pointer in
      var buffer = pointer
      return body(&buffer)
    }
  }
}
