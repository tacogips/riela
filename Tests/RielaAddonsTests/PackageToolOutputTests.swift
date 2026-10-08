import Foundation
import XCTest
import RielaAddons

final class PackageToolOutputTests: XCTestCase {
  func testDrainsBothPipesBeyondCapacityBeforeWaitingForExit() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/awk")
    process.arguments = ["""
      BEGIN {
        for (i = 0; i < 32768; i++) printf "error-line\\n" > "/dev/stderr";
        for (i = 0; i < 32768; i++) printf "output-line\\n";
        exit 7;
      }
      """]
    // A regression must fail instead of leaving the test blocked on a full pipe.
    let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
    defer { watchdog.cancel() }
    let result = try PackageToolOutput.collect(from: process)
    XCTAssertEqual(process.terminationStatus, 7)
    XCTAssertEqual(result.stdout, Data(String(repeating: "output-line\n", count: 32_768).utf8))
    XCTAssertEqual(result.stderr, Data(String(repeating: "error-line\n", count: 32_768).utf8))
  }

  func testLaunchFailureReturnsWithoutStartingReaders() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/nonexistent/riela-package-tool")
    XCTAssertThrowsError(try PackageToolOutput.collect(from: process))
  }
}
