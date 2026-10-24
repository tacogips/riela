import Foundation
import RielaCore
import XCTest
@testable import RielaAdapters

final class LocalProcessOwnerCancellationTests: XCTestCase {
  func testDeadlineAwaitsTrustedOwnerCleanupBeyondDefaultKillGrace() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/owner-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let marker = root.appendingPathComponent("cleaned")
    let script = "trap 'sleep 1.4; printf done > \"$1\"; exit 0' TERM; while :; do sleep 0.02; done"
    let start = Date()
    do {
      _ = try await FoundationLocalProcessRunner().run(configuration: .init(executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", script, "owner", marker.path], cancellationPolicy: .awaitOwner), stdin: "", deadline: Date().addingTimeInterval(0.3))
      XCTFail("deadline accepted as completion")
    } catch let error as AdapterExecutionError { XCTAssertEqual(error.code, .timeout) }
    XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path)); XCTAssertGreaterThan(Date().timeIntervalSince(start), 1.4)
  }

  func testCancellationWaitsForOwnerAndStderrCanBeDiscardedNatively() async throws {
    let result = try await FoundationLocalProcessRunner().run(configuration: .init(executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "printf metadata; printf PRIVATE >&2"], stderrCaptureByteLimit: 0), stdin: "", deadline: nil)
    XCTAssertEqual(result.stdout, "metadata"); XCTAssertEqual(result.stderr, "")
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/cancel-owner-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let ready = root.appendingPathComponent("ready"), cleaned = root.appendingPathComponent("cleaned")
    let script = "trap 'sleep 1.3; printf done > \"$2\"; exit 0' TERM; printf ready > \"$1\"; while :; do sleep 0.02; done"
    let task = Task {
      try await FoundationLocalProcessRunner().run(configuration: .init(executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", script, "owner", ready.path, cleaned.path], cancellationPolicy: .awaitOwner), stdin: "", deadline: nil)
    }
    for _ in 0..<200 {
      if FileManager.default.fileExists(atPath: ready.path) { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path)); task.cancel()
    do { _ = try await task.value; XCTFail("cancelled accepted") } catch is CancellationError {}
    XCTAssertTrue(FileManager.default.fileExists(atPath: cleaned.path))
  }
}
