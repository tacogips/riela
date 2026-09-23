import Foundation
import XCTest
@testable import RielaAdapters

final class LocalProcessStdinOwnershipTests: XCTestCase {
  func testOwnedStdinWriterDeliversBytesAndClosesEOF() async throws {
    let input = String(repeating: "stdin fixture\n", count: 10_000)
    let output = try await FoundationLocalProcessRunner().run(
      configuration: .init(executableURL: URL(fileURLWithPath: "/bin/cat")), stdin: input,
      deadline: Date().addingTimeInterval(10)
    )
    XCTAssertEqual(output.terminationStatus, 0)
    XCTAssertEqual(output.stdout, input)
  }

  func testCancellationAroundSpawnCannotAccessClosedStdinHandle() async throws {
    for _ in 0 ..< 10 {
      let writerStarted = DispatchSemaphore(value: 0)
      let operation = Task {
        try await FoundationLocalProcessRunner().run(
          configuration: .init(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"]),
          stdin: String(repeating: "x", count: 100_000), deadline: Date().addingTimeInterval(10),
          outputEventHandler: nil,
          stdinWriterStartedHandler: { writerStarted.signal() }
        )
      }
      XCTAssertEqual(writerStarted.wait(timeout: .now() + 5), .success, "stdin writer must own its descriptor before cancellation")
      operation.cancel()
      do {
        _ = try await operation.value
        XCTFail("Cancelled process must not report normal completion")
      } catch is CancellationError {
        // Expected; no FileHandle exception, descriptor reuse or process leak.
      }
    }
  }
}
