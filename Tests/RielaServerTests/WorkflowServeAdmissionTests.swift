import XCTest
@testable import RielaServer

final class WorkflowServeAdmissionTests: XCTestCase {
  func testWireAndFiltering() throws {
    let frame = WorkflowServeAdmissionFrame(type: "admission-close", requestId: "a", leaseSeconds: 120)
    XCTAssertEqual(WorkflowServeAdmissionFrame.decodeControlLine(try frame.encodedLine()), frame)
    XCTAssertNil(WorkflowServeAdmissionFrame.decodeControlLine(Data("{\"generation\":1}".utf8)))
    XCTAssertNil(WorkflowServeAdmissionAcknowledgement.decodeLine(Data("{\"type\":\"runtime-environment-ack\"}".utf8)))
    XCTAssertThrowsError(try WorkflowServeAdmissionFrame(type: "admission-close", requestId: String(repeating: "x", count: 1_048_576)).encodedLine())
  }

  func testUnsupportedAndNoGeneration() async throws {
    do {
      _ = try await InProcessWorkflowServeEventSourceHandle(status: .init(sourceId: "a", status: "running", generationId: "g"))
        .admissionControl(.init(type: "admission-close", requestId: "a"))
      XCTFail("expected unsupported")
    } catch { XCTAssertEqual(error as? WorkflowServeAdmissionError, .unsupported) }
    do {
      _ = try await WorkflowServingController().admissionControl(.init(type: "admission-close", requestId: "a"))
      XCTFail("expected no active generation")
    } catch { XCTAssertEqual(error as? WorkflowServeRuntimeEnvironmentError, .noActiveGeneration) }
  }
}
