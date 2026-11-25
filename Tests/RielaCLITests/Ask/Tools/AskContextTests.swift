import RielaCore
import XCTest
@testable import RielaCLI

@MainActor
final class AskContextTests: XCTestCase {
  func testSessionBotWorkflowAndNoneResolveOnTheHost() async throws {
    let fixture = try await AskToolFixture(test: self)
    let run = try await fixture.makeExecutor()

    let sessionResult = try await run.executor.resolveContext(AskContext(kind: .session, id: fixture.session.sessionId))
    let session = try XCTUnwrap(sessionResult)
    XCTAssertEqual(session.ref, AskRef(kind: .session, id: fixture.session.sessionId))
    XCTAssertEqual(session.summary["sessionId"], .string(fixture.session.sessionId))
    XCTAssertEqual(session.summary["status"], .string("completed"))

    let botResult = try await run.executor.resolveContext(AskContext(kind: .bot, id: AskToolFixture.botId))
    let bot = try XCTUnwrap(botResult)
    XCTAssertEqual(bot.ref, AskRef(kind: .bot, id: AskToolFixture.botId))
    XCTAssertEqual(bot.summary["name"], .string("Ask Fixture"))
    XCTAssertEqual(bot.summary["paused"], .bool(false))

    let workflowResult = try await run.executor.resolveContext(AskContext(kind: .workflow, id: AskToolFixture.workflowId))
    let workflow = try XCTUnwrap(workflowResult)
    XCTAssertEqual(workflow.ref, AskRef(kind: .workflow, id: AskToolFixture.workflowId))
    XCTAssertEqual(workflow.summary["workflowId"], .string(AskToolFixture.workflowId))

    let noContext = try await run.executor.resolveContext(AskContext())
    XCTAssertNil(noContext)
  }

  func testUnknownContextIDsFailClosed() async throws {
    let fixture = try await AskToolFixture(test: self)
    let run = try await fixture.makeExecutor()
    for kind in [AskContextKind.session, .bot, .workflow] {
      do {
        _ = try await run.executor.resolveContext(AskContext(kind: kind, id: "unknown-fixture-id"))
        XCTFail("Missing \(kind) context resolved")
      } catch let error as AskError {
        XCTAssertEqual(error.code, "ask_context_not_found")
      }
    }
  }
}
