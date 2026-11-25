import Foundation
import RielaCore
import RielaGraphQL
import Testing
@testable import RielaCLI

struct AskExampleWalkthroughTests {
  @Test func groundsTheAnswerInTheMockRun() async throws {
    let fixture = try AskSurfaceFixture()
    let bundle = fixture.examples.appendingPathComponent("ask-run-status")
    let result = await fixture.run([
      "workflow", "run", "ask-run-status", "--workflow-definition-dir", fixture.examples.path,
      "--mock-scenario", bundle.appendingPathComponent("mock-scenario.json").path,
      "--working-dir", fixture.root.path, "--session-store", fixture.sessionRoot,
      "--artifact-root", fixture.path("artifacts"), "--output", "json"
    ])
    let run = try fixture.decode(WorkflowRunResult.self, result)
    #expect(run.status == .completed)
    let id = run.session.sessionId
    let template = try String(contentsOf: bundle.appendingPathComponent("ask-script.json"), encoding: .utf8)
    let script = template.replacingOccurrences(of: "__SESSION_ID__", with: id)
    try Data(script.utf8).write(to: URL(fileURLWithPath: fixture.path("script.json")))

    let text = await fixture.ask(["--session", id, "what is the state of this run?"])
    #expect(text.exitCode == .success)
    #expect(text.stdout.contains("· session_status \(id)"))
    #expect(text.stdout.contains("The run completed."))
    #expect(text.stdout.contains("Records:\n  session:\(id)"))
    #expect(text.stdout.contains("conversation ask-"))

    let json = await fixture.ask(["--session", id, "--output", "json", "what is the state of this run?"])
    let answer = try fixture.decode(AskConversationPayload.self, json)
    #expect(answer.conversation.turn?.status == .completed)
    #expect(answer.messages.last?.citations == [AskRef(kind: .session, id: id)])
  }
}
