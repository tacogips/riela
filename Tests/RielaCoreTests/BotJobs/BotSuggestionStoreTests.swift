import Foundation
import XCTest
@testable import RielaCore

final class BotSuggestionStoreTests: XCTestCase {
  func testParseTrimsAndCapsTitleAndDecodesAction() throws {
    let longTitle = String(repeating: "é", count: 201)
    let drafts = try BotSuggestion.parseOutput(["suggestions": .array([
      .object([
        "title": .string("  \(longTitle)\n"), "detail": .string("Context"),
        "action": .object(["workflowName": .string("review"), "input": .object(["limit": .integer(3)])])
      ]),
      .object(["title": .string("Read"), "action": .object(["input": .object([:])])]),
      .object(["title": .string("Check"), "action": .object(["workflowName": .string("check")])]),
      .object(["title": .string("Inspect"), "action": .object(["workflowName": .string("inspect"), "input": .integer(1)])])
    ])])
    XCTAssertEqual(drafts, [
      BotSuggestionDraft(
        title: String(longTitle.prefix(200)), detail: "Context",
        action: BotSuggestionAction(workflowName: "review", input: ["limit": .integer(3)])
      ),
      BotSuggestionDraft(title: "Read"),
      BotSuggestionDraft(title: "Check", action: BotSuggestionAction(workflowName: "check")),
      BotSuggestionDraft(title: "Inspect")
    ])
  }

  func testParseRejectsMissingArrayAndNonStringTitles() {
    for payload: JSONObject in [
      [:], ["suggestions": .object([:])], ["suggestions": .array([.object(["title": .integer(1)])])]
    ] {
      XCTAssertThrowsError(try BotSuggestion.parseOutput(payload)) { error in
        XCTAssertEqual((error as? BotStoreError)?.code, "look_around_output_invalid")
      }
    }
  }

  func testParseKeepsFirstTwenty() throws {
    let suggestions: [JSONValue] = (1...25).map { .object(["title": .string("Suggestion \($0)")]) }
    let drafts = try BotSuggestion.parseOutput(["suggestions": .array(suggestions)])
    XCTAssertEqual(drafts.map(\.title), (1...20).map { "Suggestion \($0)" })
  }

  func testAcceptThenStartPreservesDecisionAndSource() throws {
    try withBotJobStore { store, date in
      let draft = BotSuggestionDraft(title: "Review", detail: "Details", action: BotSuggestionAction(workflowName: "review"))
      let inserted = try store.insertSuggestions(botId: "bot", drafts: [draft], sourceSessionId: "look-around-run", at: date)
      let opened = try XCTUnwrap(inserted.first)
      XCTAssertTrue(opened.suggestionId.hasPrefix("sug-"))
      XCTAssertEqual(opened.status, .open)
      XCTAssertEqual(opened.detail, draft.detail)
      XCTAssertEqual(opened.action, draft.action)
      XCTAssertEqual(opened.sourceSessionId, "look-around-run")
      XCTAssertEqual(try store.suggestions(botId: "bot", status: .open), inserted)

      let id = opened.suggestionId
      XCTAssertThrowsError(try store.markSuggestionStarted(suggestionId: id, sessionId: "early")) { error in
        XCTAssertEqual((error as? BotStoreError)?.code, "suggestion_already_decided")
      }
      let accepted = try store.acceptSuggestion(suggestionId: id, by: "user", at: date)
      XCTAssertEqual(accepted.status, .accepted)
      XCTAssertEqual(accepted.acceptedAt, RoutineStore.timestamp(date))
      XCTAssertEqual(accepted.acceptedBy, "user")
      XCTAssertNil(accepted.startedSessionId)
      XCTAssertEqual(try store.suggestions(botId: "bot", status: .accepted), [accepted])
      XCTAssertTrue(try store.suggestions(botId: "bot", status: .open).isEmpty)
      XCTAssertThrowsError(try store.acceptSuggestion(suggestionId: id, by: "other", at: date)) { error in
        XCTAssertEqual((error as? BotStoreError)?.code, "suggestion_already_decided")
      }
      XCTAssertThrowsError(try store.dismissSuggestion(suggestionId: id, by: "other", reason: nil, at: date)) { error in
        XCTAssertEqual((error as? BotStoreError)?.code, "suggestion_already_decided")
      }
      let started = try store.markSuggestionStarted(suggestionId: id, sessionId: "review-run")
      XCTAssertEqual(started.status, .started)
      XCTAssertEqual(started.startedSessionId, "review-run")
      XCTAssertEqual(started.acceptedBy, "user")
      XCTAssertEqual(started.sourceSessionId, "look-around-run")
      XCTAssertEqual(try store.suggestions(botId: "bot"), [started])
    }
  }

  func testDismissPersistsReasonAndUnknownDecisionFails() throws {
    try withBotJobStore { store, date in
      let draft = BotSuggestionDraft(title: "Review")
      let first = try store.insertSuggestions(botId: "bot", drafts: [draft], sourceSessionId: nil, at: date)
      let later = date.addingTimeInterval(1)
      let second = try store.insertSuggestions(botId: "bot", drafts: [draft], sourceSessionId: nil, at: later)
      XCTAssertEqual(try store.suggestions(botId: "bot", status: .open), second + first)

      let id = try XCTUnwrap(first.first?.suggestionId)
      let dismissed = try store.dismissSuggestion(suggestionId: id, by: "user", reason: "Handled", at: later)
      XCTAssertEqual(dismissed.status, .dismissed)
      XCTAssertEqual(dismissed.dismissedAt, RoutineStore.timestamp(later))
      XCTAssertEqual(dismissed.dismissedBy, "user")
      XCTAssertEqual(dismissed.dismissReason, "Handled")
      XCTAssertEqual(try store.suggestions(botId: "bot", status: .dismissed), [dismissed])
      XCTAssertThrowsError(try store.acceptSuggestion(suggestionId: "missing", by: "user", at: date)) { error in
        XCTAssertEqual((error as? BotStoreError)?.code, "suggestion_not_found")
      }
    }
  }
}
