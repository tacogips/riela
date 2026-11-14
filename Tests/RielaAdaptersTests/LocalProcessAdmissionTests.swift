import Foundation
import RielaCore
import XCTest
@testable import RielaAdapters

final class LocalProcessAdmissionTests: XCTestCase {
  func testExpiredDeadlineRejectsBeforeExecutableResolution() async throws {
    do {
      _ = try await FoundationLocalProcessRunner().run(
        configuration: .init(executableURL: URL(fileURLWithPath: "/riela-fixture-must-not-launch")),
        stdin: "", deadline: Date().addingTimeInterval(-1))
      XCTFail("An expired invocation must not launch")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .timeout)
    }
  }

  func testPreCancelledTaskRejectsBeforeExecutableResolution() async throws {
    let operation = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await FoundationLocalProcessRunner().run(
        configuration: .init(executableURL: URL(fileURLWithPath: "/riela-fixture-must-not-launch")),
        stdin: "", deadline: Date().addingTimeInterval(10))
    }
    do {
      _ = try await operation.value
      XCTFail("A cancelled invocation must not launch")
    } catch is CancellationError {
      // Cancellation must win before posix_spawn can resolve the executable.
    }
  }
}
