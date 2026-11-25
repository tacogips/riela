import RielaCore
import XCTest

final class AskRoundsProtocolTests: XCTestCase {
  func testFencedToolAndMessageLines() {
    let round = AskRoundsProtocol.parse("""
      ```ndjson
      {"type":"tool","name":"session_list"}
      {"type":"tool","id":"status","name":"session_status","arguments":{"sessionId":"s1"}}
      {"type":"message","text":"Checking [[session:s1]]."}
      ```
      """)
    XCTAssertEqual(round.toolCalls.map(\.name), ["session_list", "session_status"])
    XCTAssertEqual(round.toolCalls.map(\.id), ["t0", "status"])
    XCTAssertEqual(round.toolCalls.map(\.arguments), [[:], ["sessionId": .string("s1")]])
    XCTAssertEqual(round.answerText, "Checking [[session:s1]].")
  }

  func testPlainProseKeepsWhitespace() {
    let prose = "  The session is running.\r\n\r\n  Its first step is complete.\r\n"
    let round = AskRoundsProtocol.parse(prose)
    XCTAssertTrue(round.toolCalls.isEmpty)
    XCTAssertEqual(round.answerText, prose)
  }

  func testProtocolLineEndingIsFraming() {
    let message = #"{"type":"message","text":"Answer"}"# + "\n"
    XCTAssertEqual(AskRoundsProtocol.parse(message).answerText, "Answer")
  }

  func testMalformedAndUnknownRecordsAreProse() {
    let prose = """
      {"type":"tool"}
      {"type":"tool","name":"bot_list","arguments":[]}
      {"type":"tool","name":"bot_list","id":1}
      {"type":"message"}
      {"type":"notice","text":"hello"}
      ["not", "an", "object"]
      """
    let round = AskRoundsProtocol.parse(prose)
    XCTAssertTrue(round.toolCalls.isEmpty)
    XCTAssertEqual(round.answerText, prose)
  }

  func testDropsToolCallsAfterEight() {
    let calls = (0..<10).map { index in #"{"type":"tool","name":"bot_list","id":"\#(index)"}"# }
    let round = AskRoundsProtocol.parse(calls.joined(separator: "\r\n"))
    XCTAssertEqual(round.toolCalls.map(\.id), (0..<8).map(String.init))
    XCTAssertEqual(round.answerText, "")
  }
}
