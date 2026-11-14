import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import RielaAdapters

final class LocalProcessCancellationTreeTests: XCTestCase {
  func testDescendantsExcludeRootsAndUnrelatedProcesses() {
    let entries = [
      LocalProcessTreeEntry(pid: 1, ppid: 0, pgid: 1, startTime: 1),
      LocalProcessTreeEntry(pid: 2, ppid: 1, pgid: 1, startTime: 2),
      LocalProcessTreeEntry(pid: 3, ppid: 2, pgid: 3, startTime: 3),
      LocalProcessTreeEntry(pid: 4, ppid: 9, pgid: 4, startTime: 4)
    ]
    XCTAssertEqual(Set(localProcessDescendants(of: [1], in: entries).map(\.pid)), [2, 3])
  }

  func testSameGroupCancellationReclaimsChild() async throws {
    try await assertTreeReclaimed(separateGroup: false)
  }

  func testSeparateGroupSurvivesLeaderExitUntilEscalation() async throws {
    try await assertTreeReclaimed(separateGroup: true)
  }

  func testPIDReuseIsNotSignalled() {
    let recorder = TreeSignalRecorder()
    let handle = LocalProcessHandle(
      signalProcess: { pid, signal in recorder.record(pid, signal); return 0 },
      snapshotter: ReusedPIDSnapshotter(), cancellationGrace: 0.01,
      cancellationHardBound: 0.01, cancellationScanInterval: 0.001
    )
    handle.store(processId: 1234)
    handle.beginTaskCancellation(markCancelled: {})
    handle.waitForCancellation()
    XCTAssertFalse(recorder.pids.contains(4242))
  }

  func testCooperativeCleanupFinishesAfterLeaderExits() async throws {
    try await assertTreeReclaimed(separateGroup: true, cooperative: true)
  }

  func testChildlessLeaderGetsGraceForCooperativeCleanup() async throws {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repo.appendingPathComponent("tmp/instance-cancel/instance-cancel-03-localprocess-tree/fixtures/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let leaderFile = root.appendingPathComponent("leader")
    let cleanedFile = root.appendingPathComponent("cleaned")
    defer {
      if let text = try? String(contentsOf: leaderFile, encoding: .utf8),
         let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) { _ = kill(pid, SIGKILL) }
      try? FileManager.default.removeItem(at: root)
    }
    let script = "trap 'sleep 0.5; touch \"$2\"; exit 0' TERM; echo $$ > \"$1\"; while :; do :; done"
    let task = Task {
      try await FoundationLocalProcessRunner().run(
        configuration: .init(executableURL: URL(fileURLWithPath: "/bin/sh"),
                             arguments: ["-c", script, "leader", leaderFile.path, cleanedFile.path]), stdin: ""
      )
    }
    let deadline = Date().addingTimeInterval(10)
    while !FileManager.default.fileExists(atPath: leaderFile.path), Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    guard let text = try? String(contentsOf: leaderFile, encoding: .utf8),
          let leader = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      task.cancel()
      _ = try? await task.value
      XCTFail("Fixture did not start")
      return
    }
    let start = Date()
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {}
    XCTAssertLessThan(Date().timeIntervalSince(start), 12)
    XCTAssertTrue(FileManager.default.fileExists(atPath: cleanedFile.path))
    XCTAssertEqual(kill(leader, 0), -1)
    XCTAssertEqual(errno, ESRCH)
  }

  private func assertTreeReclaimed(separateGroup: Bool, cooperative: Bool = false) async throws {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repo.appendingPathComponent("tmp/instance-cancel/instance-cancel-03-localprocess-tree/fixtures/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let pidFile = root.appendingPathComponent("child")
    let leaderFile = root.appendingPathComponent("leader")
    let cleanedFile = root.appendingPathComponent("cleaned")
    defer {
      for file in [pidFile, leaderFile] {
        if let text = try? String(contentsOf: file, encoding: .utf8),
           let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) { _ = kill(pid, SIGKILL) }
      }
      try? FileManager.default.removeItem(at: root)
    }
    let script: String
    if cooperative {
      script = """
      echo $$ > '\(leaderFile.path)'
      trap 'exit 0' TERM
      set -m
      /bin/sh -c 'trap "trap \\\"\\\" TERM; sleep 2; touch \"$2\"; exit 0" TERM; echo $$ > "$1"; while :; do sleep 0.02; done' child '\(pidFile.path)' '\(cleanedFile.path)' &
      wait
      """
    } else if separateGroup {
      script = """
      echo $$ > '\(leaderFile.path)'
      trap 'exit 0' TERM
      set -m
      /bin/sh -c 'trap "" TERM; echo $$ > "$1"; exec /bin/sleep 300' child '\(pidFile.path)' &
      wait
      """
    } else {
      script = "echo $$ > '\(leaderFile.path)'; /bin/sleep 300 & echo $! > '\(pidFile.path)'; wait"
    }
    let task = Task {
      try await FoundationLocalProcessRunner().run(
        configuration: .init(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script]), stdin: ""
      )
    }
    let deadline = Date().addingTimeInterval(10)
    while !FileManager.default.fileExists(atPath: pidFile.path), Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    guard let value = try? String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
          let pid = pid_t(value) else {
      task.cancel()
      _ = try? await task.value
      XCTFail("Fixture did not start")
      return
    }
    let leaderText = try String(contentsOf: leaderFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    let leader = try XCTUnwrap(pid_t(leaderText))
    let cancelStarted = Date()
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {}
    XCTAssertLessThan(Date().timeIntervalSince(cancelStarted), 12)
    if cooperative {
      XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(cancelStarted), 2)
      XCTAssertTrue(FileManager.default.fileExists(atPath: cleanedFile.path))
    }
    XCTAssertEqual(kill(pid, 0), -1)
    XCTAssertEqual(errno, ESRCH)
    XCTAssertEqual(kill(leader, 0), -1)
    XCTAssertEqual(errno, ESRCH)
  }
}

private final class TreeSignalRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [pid_t] = []
  var pids: [pid_t] { lock.withLock { recorded } }
  func record(_ pid: pid_t, _ signal: Int32) { lock.withLock { recorded.append(pid) } }
}

private final class ReusedPIDSnapshotter: LocalProcessTreeSnapshotting, @unchecked Sendable {
  private let lock = NSLock()
  private var calls = 0
  func snapshot() -> [LocalProcessTreeEntry] {
    lock.withLock {
      calls += 1
      return [LocalProcessTreeEntry(pid: 4242, ppid: 1234, pgid: 4242, startTime: calls == 1 ? 1 : 2)]
    }
  }
}
