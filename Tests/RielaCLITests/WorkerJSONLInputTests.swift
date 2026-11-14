import Foundation
import RielaAdapters
import RielaCore
import XCTest
@testable import RielaCLI

final class WorkerJSONLInputTests: XCTestCase {
  func testUnicodeSeparatorsInsideStringsRemainOneJSONLRecord() throws {
    let value = ["text": "one\u{85}two\u{2028}three\u{2029}four"]
    var bytes = try JSONEncoder().encode(value); bytes.append(10)
    XCTAssertEqual(try WorkerJSONLInput.decode([String: String].self, from: bytes, framingMessage: "frame"), value)
  }

  func testMissingInputIsDistinctFromMalformedOrMultipleRecords() throws {
    for bytes in [Data(), Data(" \t\r\n".utf8)] {
      XCTAssertThrowsError(try WorkerJSONLInput.decode([String: String].self, from: bytes, framingMessage: "frame")) {
        XCTAssertTrue($0 is EmptyWorkerInput)
      }
    }
    for bytes in [Data([0xff]), Data("{}\n{}\n".utf8), Data("{".utf8)] {
      XCTAssertThrowsError(try WorkerJSONLInput.decode([String: String].self, from: bytes, framingMessage: "frame")) {
        XCTAssertFalse($0 is EmptyWorkerInput)
      }
    }
    XCTAssertEqual(PrivateWorkflowWorker.failure(for: EmptyWorkerInput()).message, WorkerJSONLInput.privateEmptyMessage)
    XCTAssertEqual(PrivateWorkflowWorker.failure(for: AdapterExecutionError(.invalidInput, WorkerJSONLInput.privateEmptyMessage)).message,
      "private workflow execution failed")
  }

  func testOnlySoleTrustedPreRequestRefusalPermitsReattach() throws {
    let record = SandboxNodeRecord(kind: .failure, failure: .init(.init(.invalidInput, WorkerJSONLInput.nodeEmptyMessage)))
    let text = String(decoding: try JSONEncoder().encode(record), as: UTF8.self) + "\n"
    let result = LocalProcessResult(stdout: text, stderr: "", terminationStatus: 0)
    XCTAssertTrue(EphemeralContainerNodeProcess.refusedEmptyInput(result, worker: SandboxNodeWorker.command))
    for rejected in [LocalProcessResult(stdout: text + text, stderr: "", terminationStatus: 0),
      LocalProcessResult(stdout: text, stderr: "work already produced stderr", terminationStatus: 0),
      LocalProcessResult(stdout: text, stderr: "", terminationStatus: 1)] {
      XCTAssertFalse(EphemeralContainerNodeProcess.refusedEmptyInput(rejected, worker: SandboxNodeWorker.command))
    }
    XCTAssertFalse(EphemeralContainerNodeProcess.refusedEmptyInput(result, worker: PrivateWorkflowWorker.command))
  }
}
