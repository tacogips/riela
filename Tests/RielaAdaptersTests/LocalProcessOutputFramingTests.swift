import Foundation
import XCTest
@testable import RielaAdapters

final class LocalProcessOutputFramingTests: XCTestCase {
  func testLongLinesPreserveUTF8CRLFAndFinalUnterminatedLine() async throws {
    let longLine = String(repeating: "a", count: 4_095) + String(repeating: "日本語🙂", count: 100_000)
    let input = longLine + "\r\n\nshort\r\nfinal🙂"
    let events = ProcessOutputEvents()
    let result = try await FoundationLocalProcessRunner().run(
      configuration: .init(executableURL: URL(fileURLWithPath: "/bin/cat")),
      stdin: input, deadline: Date().addingTimeInterval(10),
      outputEventHandler: { events.record($0) }
    )
    XCTAssertEqual(result.terminationStatus, 0)
    XCTAssertEqual(result.stdout, input)
    XCTAssertEqual(events.lines, [longLine, "short", "final🙂"])
  }

  func testUnobservedLongOutputIsReturnedIntact() async throws {
    let input = String(repeating: "x", count: 4 * 1_024 * 1_024)
    let result = try await FoundationLocalProcessRunner().run(
      configuration: .init(executableURL: URL(fileURLWithPath: "/bin/cat")),
      stdin: input, deadline: Date().addingTimeInterval(10)
    )
    XCTAssertEqual(result.terminationStatus, 0)
    XCTAssertEqual(result.stdout, input)
  }
}

private final class ProcessOutputEvents: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [LocalProcessOutputEvent] = []
  var lines: [String] { lock.withLock { events.map(\.line) } }
  func record(_ event: LocalProcessOutputEvent) { lock.withLock { events.append(event) } }
}
