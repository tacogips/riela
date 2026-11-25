import Foundation
import RielaCore
import RielaGraphQL
import Testing
@testable import RielaCLI

struct AskCommandTests {
  @Test func startsRepliesListsShowsAndRemoves() async throws {
    let fixture = try AskSurfaceFixture()
    try fixture.script(["Fixture answer."])
    let initial = try fixture.decode(AskConversationPayload.self, await fixture.ask(["--output", "json", "state?"]))
    let id = initial.conversation.conversationId
    #expect(initial.conversation.turn?.status == .completed)
    #expect(initial.messages.last?.text == "Fixture answer.")

    let reply = await fixture.ask(["--conversation", id, "--output", "json", "again"])
    let same = try fixture.decode(AskConversationPayload.self, reply)
    #expect(same.conversation.conversationId == id)
    #expect(same.messages.filter { $0.role == .user }.map(\.text) == ["state?", "again"])

    let list = try fixture.decode(AskConversationListPayload.self, await fixture.ask(["list", "--output", "json"]))
    #expect(list.conversations.map(\.conversationId) == [id])
    let show = await fixture.ask(["show", "--follow", id])
    #expect(show.stdout.contains("Fixture answer."))
    #expect(show.stdout.contains("conversation \(id)"))
    let cancelled = try fixture.decode(AskConversationPayload.self, await fixture.ask(["cancel", id, "--output", "json"]))
    #expect(cancelled.conversation == same.conversation)
    let removed = try fixture.decode(AskConversationListPayload.self, await fixture.ask(["remove", id, "--output", "json"]))
    #expect(removed.conversations.isEmpty)
    let missing = await fixture.ask(["show", id])
    #expect(missing.exitCode == .failure)
    #expect(missing.stderr.contains("ask_conversation_not_found"))
  }

  @Test func supportsLiteralVerbAndRejectsConflictingContexts() async throws {
    let fixture = try AskSurfaceFixture()
    try fixture.script(["Fixture answer."])
    let literal = try fixture.decode(AskConversationPayload.self, await fixture.ask(["--output", "json", "--", "list"]))
    #expect(literal.messages.first?.text == "list")
    let conflict = await fixture.ask(["--session", "a", "--bot", "b", "state?"])
    #expect(conflict.exitCode == .usage)
    #expect(try fixture.store.askConversations().count == 1)
  }

  @Test func localNoFollowRejectsBeforeLoadingAdapterOrWritingNewRecords() async throws {
    let fixture = try AskSurfaceFixture()
    // Invalid script data would fail before a turn starts if send reached adapter selection.
    try Data("invalid script".utf8).write(to: URL(fileURLWithPath: fixture.path("script.json")))
    let denied = await fixture.ask(["--no-follow", "state?"])
    #expect(denied.exitCode == .usage)
    #expect(denied.stderr.contains("--remote"))
    #expect(denied.stdout.isEmpty)
    #expect(try fixture.store.askConversations().isEmpty)
  }

  @Test func localNoFollowDoesNotChangeAnExistingConversation() async throws {
    let fixture = try AskSurfaceFixture()
    try fixture.script(["Fixture answer."])
    let initial = try fixture.decode(AskConversationPayload.self, await fixture.ask(["--output", "json", "state?"]))
    let id = initial.conversation.conversationId
    let denied = await fixture.ask(["--conversation", id, "--no-follow", "again"])
    #expect(denied.exitCode == .usage)
    #expect(denied.stderr.contains("--remote"))
    #expect(try fixture.store.askConversation(id: id) == initial.conversation)
    #expect(try fixture.store.askMessages(conversationId: id) == initial.messages)
  }

  @Test func confirmsAndDismissesProposalsThroughTheCommand() async throws {
    let fixture = try AskSurfaceFixture()
    try fixture.seedBot()
    try fixture.script([AskSurfaceFixture.pauseProposal, "I proposed pausing the bot."])
    let initial = try fixture.decode(AskConversationPayload.self, await fixture.ask(["--output", "json", "pause?"]))
    let action = try #require(initial.actions.first)
    #expect(action.status == .proposed)
    #expect(try fixture.store.load(botId: "fixture-bot")?.paused == false)

    let confirmation = await fixture.ask(["confirm", initial.conversation.conversationId, action.actionId, "--output", "json"])
    let confirmed = try fixture.decode(AskConversationPayload.self, confirmation)
    #expect(confirmed.actions.first?.status == .confirmed)
    #expect(try fixture.store.load(botId: "fixture-bot")?.paused == true)

    let second = try fixture.decode(AskConversationPayload.self, await fixture.ask(["--output", "json", "new proposal?"]))
    let next = try #require(second.actions.first)
    let dismissal = await fixture.ask(["dismiss", second.conversation.conversationId, next.actionId, "--output", "json"])
    #expect(try fixture.decode(AskConversationPayload.self, dismissal).actions.first?.status == .dismissed)
  }

  @Test func warnsOnItsOwnLineAndReportsFailedTurnsWithoutAnAnswer() async throws {
    let fixture = try AskSurfaceFixture()
    try fixture.script(["Fixture answer."])
    let warned = await fixture.ask(["--model", "unknown-x", "state?"])
    #expect(warned.exitCode == .success)
    #expect(warned.stderr.split(separator: "\n").count == 1)
    #expect(warned.stderr.hasPrefix("model_unknown:"))
    #expect(warned.stdout.contains("Fixture answer."))

    let scratch = URL(fileURLWithPath: fixture.sessionRoot, isDirectory: true).appendingPathComponent("ask-turns")
    try FileManager.default.removeItem(at: scratch)
    try Data().write(to: scratch)
    let failed = await fixture.ask(["state?"])
    #expect(failed.exitCode == .failure)
    #expect(failed.stderr.contains("ask_provider_error"))
    #expect(!failed.stdout.contains("Fixture answer."))
  }
}
