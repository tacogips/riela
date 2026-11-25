import RielaCore
import RielaGraphQL
import XCTest

final class BotActivityGraphQLTests: XCTestCase {
  func testActivityDefaultsAndNestedPayloadProjection() async {
    let provider = RecordingBotsProvider()
    let executor = BotsGraphQLDocumentExecutor(provider: provider)
    let response = await executor.execute(request("""
      {
        replay: botActivity(sessionId: "session") {
          events { sessionId seq at kind payload }
          state { source configOptions usage }
          lastSequence firstRetainedSequence truncated activitySource sessionStatus
          origin { remote verified }
        }
      }
      """))
    let calls = await provider.calls
    XCTAssertEqual(calls, ["activity:session:0:200:0:"])
    XCTAssertEqual(response.body["data"], .object(["replay": .object([
      "events": .array([.object([
        "sessionId": .string("session"), "seq": .integer(7), "at": .string("1970-01-01T00:00:00Z"),
        "kind": .string("message"), "payload": .object(["text": .string("hello")])
      ])]),
      "state": .object([
        "source": .string("acp"), "configOptions": .array([.object(["id": .string("model")])]),
        "usage": .object(["used": .integer(3)])
      ]),
      "lastSequence": .integer(7), "firstRetainedSequence": .integer(7), "truncated": .bool(true),
      "activitySource": .string("acp"), "sessionStatus": .string("running"),
      "origin": .object(["remote": .string("local"), "verified": .bool(true)])
    ])]))
  }

  func testActivityClampsWaitAndLimitBeforeCallingProvider() async {
    let provider = RecordingBotsProvider()
    let executor = BotsGraphQLDocumentExecutor(provider: provider)
    let response = await executor.execute(request("""
      {
        high: botActivity(sessionId: "session", afterSequence: 3, limit: 999, waitMs: 60000, remote: "local") { lastSequence }
        low: botActivity(sessionId: "session", afterSequence: 2, limit: -1, waitMs: -1) { lastSequence }
      }
      """))
    let calls = await provider.calls
    XCTAssertNil(response.body["errors"])
    XCTAssertEqual(calls, ["activity:session:3:500:25000:local", "activity:session:2:1:0:"])
  }

  func testAnswerRequiresTrustedMutationAndRelaysNativeOptionID() async {
    let provider = RecordingBotsProvider()
    let executor = BotsGraphQLDocumentExecutor(provider: provider)
    let field = """
      answerBotRequest(input: {requestId: "request", optionId: "native/allow.1", remote: "local"}) {
        requestId status outcomeOptionId resolvedBy
      }
      """
    let denied = await executor.execute(request("mutation { \(field) }", trusted: false))
    XCTAssertEqual(errorCode(denied), "BOTS_UNAVAILABLE")
    let wrongOperation = await executor.execute(request("{ \(field) }"))
    XCTAssertEqual(errorCode(wrongOperation), "INVALID_BOT")
    let accepted = await executor.execute(request("mutation { answer: \(field) }"))
    let calls = await provider.calls
    XCTAssertEqual(calls, ["answer:request:native/allow.1:false:local"])
    XCTAssertEqual(accepted.body["data"], .object(["answer": .object([
      "requestId": .string("request"), "status": .string("answered"),
      "outcomeOptionId": .string("native/allow.1"), "resolvedBy": .string("user")
    ])]))
  }

  func testActivityAuthenticationErrorIsPreserved() async {
    let provider = RecordingBotsProvider(activityError: BotStoreError(code: "UNAUTHENTICATED", message: "Activity access was revoked"))
    let executor = BotsGraphQLDocumentExecutor(provider: provider)
    let response = await executor.execute(request("{ botActivity(sessionId: \"session\", waitMs: 1000) { events { seq } } }"))
    XCTAssertEqual(errorCode(response), "UNAUTHENTICATED")
    XCTAssertEqual(response.body["data"], .null)
  }

  private func request(_ query: String, trusted: Bool = true) -> GraphQLDocumentRequest {
    GraphQLDocumentRequest(query: query, environment: [:], isLocallyTrusted: trusted)
  }

  private func errorCode(_ response: GraphQLDocumentExecutionResponse) -> String? {
    guard case let .array(errors)? = response.body["errors"],
      case let .object(error)? = errors.first,
      case let .object(details)? = error["extensions"],
      case let .string(code)? = details["code"] else { return nil }
    return code
  }
}
