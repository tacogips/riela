#if canImport(AppleGatewayCore)
import AppleGatewayCore
import Foundation
import XCTest

final class AppleGatewayLinkedDeadlineTests: XCTestCase {
  func testLinkedSDKStopsTimedOutChildWithoutReadReplay() throws {
    XCTAssertEqual(AppleGatewayCore.Version.current, "0.1.16")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("riela-apple-deadline-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let count = root.appendingPathComponent("count")
    let executable = root.appendingPathComponent("stub")
    try """
    #!/bin/sh
    echo attempt >> "$COUNT_FILE"
    exec /bin/sleep 30
    """.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let bridge = AppleEventBridge(osascriptPath: executable.path, timeoutSeconds: 30,
      environment: ["COUNT_FILE": count.path], maxTimeoutRetries: 3,
      terminationGraceSeconds: 0.05, temporaryDirectory: root)
    let started = ProcessInfo.processInfo.systemUptime
    XCTAssertThrowsError(try AppleWriteExecutionContext.withDeadline(Date().addingTimeInterval(2)) {
      try bridge.runJXA(script: "offline fixture", argumentsJSON: "{}")
    }) { error in
      guard case AppleEventBridgeError.timeout = error else { return XCTFail("Expected deadline timeout") }
    }
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 5)
    XCTAssertEqual(try String(contentsOf: count, encoding: .utf8), "attempt\n")
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path)
      .contains { $0.hasPrefix("apple-gateway-osascript-") })
  }
}
#endif
