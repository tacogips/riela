import XCTest
@testable import RielaCore

final class LoopFindingFingerprintTests: XCTestCase {
  func testFingerprintPrefersAuthoredId() {
    let first = LoopFindingFingerprint.make(from: LoopBlockingFinding(
      id: "finding-1",
      severity: "high",
      filePath: "Sources/A.swift",
      line: 10,
      message: "message"
    ))
    let second = LoopFindingFingerprint.make(from: LoopBlockingFinding(
      id: "finding-1",
      severity: "medium",
      filePath: "Sources/B.swift",
      line: 20,
      message: "changed"
    ))

    XCTAssertEqual(first, second)
  }

  func testFingerprintFallsBackForSynthesizedGatePolicyIds() {
    let first = LoopFindingFingerprint.make(from: LoopBlockingFinding(
      id: "gate-policy-review-decision",
      severity: "high",
      filePath: "Sources/A.swift",
      line: 10,
      message: "Needs   work\nagain"
    ))
    let second = LoopFindingFingerprint.make(from: LoopBlockingFinding(
      id: "gate-policy-review-max-high-findings",
      severity: "low",
      filePath: "Sources/A.swift",
      line: 99,
      message: "Needs work again"
    ))

    XCTAssertEqual(first, second)
  }

  func testFingerprintFallbackExcludesLineAndSeverity() {
    let first = LoopFindingFingerprint.make(from: LoopBlockingFinding(
      id: "",
      severity: "high",
      filePath: nil,
      line: 1,
      message: "  same\tmessage "
    ))
    let second = LoopFindingFingerprint.make(from: LoopBlockingFinding(
      id: "",
      severity: "medium",
      filePath: nil,
      line: 100,
      message: "same message"
    ))

    XCTAssertEqual(first, second)
  }
}
