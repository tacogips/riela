import Foundation
import XCTest
@testable import RielaServer

final class WorkflowServeSessionControlTests: XCTestCase {
  func testFramesAndAcknowledgementsRoundTrip() throws {
    let frames = [WorkflowServeSessionControlFrame(type: "session-list", requestId: "1"),
                  WorkflowServeSessionControlFrame(type: "session-cancel", requestId: "2", sessionId: "s", reason: "r", actor: "a")]
    for frame in frames {
      let data = try frame.encodedLine()
      XCTAssertEqual(data.last, 10)
      XCTAssertEqual(WorkflowServeSessionControlFrame.decodeControlLine(data), frame)
      XCTAssertNil(WorkflowServeAdmissionFrame.decodeControlLine(data))
    }
    let acks = [WorkflowServeSessionControlAcknowledgement.cancelAck(requestId: "1", sessionId: "s", outcome: .cancelRequested),
                WorkflowServeSessionControlAcknowledgement.listAck(requestId: "2", sessionIds: ["s"], pendingRunCount: 1)]
    for ack in acks {
      XCTAssertEqual(WorkflowServeSessionControlAcknowledgement.decodeLine(try JSONEncoder().encode(ack)), ack)
    }
  }

  func testRejectsInvalidFrames() throws {
    let admission = try WorkflowServeAdmissionFrame(type: "admission-close", requestId: "1").encodedLine()
    XCTAssertNil(WorkflowServeSessionControlFrame.decodeControlLine(admission))
    for data in [Data(#"{"generation":1}"#.utf8), Data(#"{"type":"unknown","requestId":"1"}"#.utf8),
                 Data(repeating: 32, count: WorkflowServeAdmissionWire.maxFrameBytes + 1)] {
      XCTAssertNil(WorkflowServeSessionControlFrame.decodeControlLine(data))
      XCTAssertNil(WorkflowServeSessionControlAcknowledgement.decodeLine(data))
    }
    for reason in [String(repeating: "a", count: 513), "a\0b", ""] {
      let frame = WorkflowServeSessionControlFrame(type: "session-cancel", requestId: "1", sessionId: "s", reason: reason, actor: "a")
      XCTAssertNil(WorkflowServeSessionControlFrame.decodeControlLine(try frame.encodedLine()))
    }
    for frame in [WorkflowServeSessionControlFrame(type: "session-cancel", requestId: "1", reason: "r", actor: "a"),
                  WorkflowServeSessionControlFrame(type: "session-cancel", requestId: "1", sessionId: "s", reason: "r", actor: "")] {
      XCTAssertNil(WorkflowServeSessionControlFrame.decodeControlLine(try frame.encodedLine()))
    }
  }
}
