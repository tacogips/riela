import Foundation
import XCTest
@testable import RielaCore

final class ActivityReducerTests: XCTestCase {
  private let at = Date(timeIntervalSince1970: 1_700_000_000)
  private let executionId = "execution"

  func testUnknownToolUpdateCreatesCallWithProvidedFields() {
    var state = ActivityState()
    let location = AdapterActivityLocation(path: "Sources/File.swift", line: 9)
    let events = apply(.toolCall(.init(toolCallId: "read", status: "in_progress", locations: [location])), to: &state)

    XCTAssertEqual(events.map(\.kind), [.toolCall])
    XCTAssertEqual(events.first?.payload["toolCallId"], .string("read"))
    XCTAssertEqual(events.first?.payload["status"], .string("inProgress"))
    XCTAssertEqual(state.toolCalls, [.init(toolCallId: "read", status: "inProgress", locations: [location], updatedAt: at)])
    XCTAssertEqual(state.source, "acp")
  }

  func testTerminalStatusIgnoresAnOutOfOrderOpenUpdate() {
    var state = ActivityState()
    _ = apply(.toolCall(.init(toolCallId: "read", status: "completed")), to: &state)

    let events = apply(
      .toolCall(.init(toolCallId: "read", status: "in_progress")),
      to: &state, at: at.addingTimeInterval(1)
    )

    XCTAssertTrue(events.isEmpty)
    XCTAssertEqual(state.toolCalls, [.init(toolCallId: "read", status: "completed", updatedAt: at)])
  }

  func testTitlePatchPreservesUnspecifiedToolFields() {
    var state = ActivityState()
    _ = apply(.toolCall(.init(toolCallId: "read", title: "Original", toolKind: "read", status: "pending")), to: &state)

    let events = apply(.toolCall(.init(toolCallId: "read", title: "Read the fixture")), to: &state)

    XCTAssertEqual(events.map(\.kind), [.toolCall])
    XCTAssertEqual(events.first?.payload["title"], .string("Read the fixture"))
    XCTAssertEqual(state.toolCalls, [
      .init(toolCallId: "read", title: "Read the fixture", toolKind: "read", status: "pending", updatedAt: at)
    ])
  }

  func testPlanReplacementAndRemovalKeepFirstSeenOrder() {
    var state = ActivityState()
    let entry = planEntry("First")
    let done = planEntry("Second", status: "completed")
    let remaining = planEntry("Only in second plan")
    _ = apply(.plan(planId: "first", entries: [entry, done]), to: &state)
    _ = apply(.plan(planId: "second", entries: [remaining]), to: &state)

    let active = planEntry("Revised first", status: "in_progress")
    let replacement = apply(.plan(planId: "first", entries: [active]), to: &state)

    XCTAssertEqual(replacement.map(\.kind), [.plan])
    XCTAssertEqual(state.plans.map(\.planId), ["first", "second"])
    XCTAssertEqual(state.plans.map(\.entries), [[planEntry("Revised first", status: "inProgress")], [remaining]])

    let removal = apply(.planRemoved(planId: "first"), to: &state)
    XCTAssertEqual(removal.map(\.kind), [.planRemoved])
    XCTAssertEqual(state.plans, [.init(planId: "second", entries: [remaining])])
  }

  func testToolCallCapEvictsOldestTerminalCallsBeforeOpenCalls() {
    var state = ActivityState()
    for index in 0..<205 {
      _ = apply(
        .toolCall(.init(toolCallId: "call-\(index)", status: index < 5 ? "pending" : "completed")),
        to: &state, at: at.addingTimeInterval(Double(index))
      )
    }

    XCTAssertEqual(state.toolCalls.count, 200)
    let retained = Set(state.toolCalls.map(\.toolCallId))
    XCTAssertEqual(retained, Set((Array(0..<5) + Array(10..<205)).map { "call-\($0)" }))
    XCTAssertEqual(state.toolCalls.filter { $0.status == "pending" }.count, 5)
  }

  func testSettlementClosesOpenItemsAndIsIdempotent() {
    var state = ActivityState()
    state.currentExecutionId = executionId
    state.currentStepId = "step"
    state.toolCalls = [
      .init(toolCallId: "calling", status: "inProgress", updatedAt: at),
      .init(toolCallId: "queued", status: "pending", updatedAt: at),
      .init(toolCallId: "done", status: "completed", updatedAt: at)
    ]
    state.plans = [
      .init(planId: "plan", entries: [
        planEntry("one"), planEntry("two", status: "inProgress"), planEntry("three"),
        planEntry("done", status: "completed")
      ])
    ]
    state.subagents = [
      .init(subSessionId: "worker", title: "Worker", state: "running"),
      .init(subSessionId: "finished", title: "Finished", state: "completed")
    ]
    let finishedAt = at.addingTimeInterval(3)

    let events = ActivityReducer.settle(state: &state, reason: .providerError, stepStatus: "failed", at: finishedAt)

    XCTAssertEqual(events.map(\.kind), [.stepFinished, .settled])
    XCTAssertEqual(events.last?.payload["reason"], .string("providerError"))
    XCTAssertEqual(events.last?.payload["closed"], .object([
      "toolCalls": .integer(2), "planEntries": .integer(3),
      "subagents": .integer(1), "permissionRequests": .integer(0)
    ]))
    XCTAssertEqual(state.toolCalls.map(\.status), ["interrupted", "interrupted", "completed"])
    XCTAssertEqual(state.plans.first?.entries.map(\.status), ["abandoned", "abandoned", "abandoned", "completed"])
    XCTAssertEqual(state.subagents.map(\.state), ["interrupted", "completed"])
    XCTAssertNil(state.currentExecutionId)

    let settledState = state
    XCTAssertTrue(ActivityReducer.settle(state: &state, reason: .providerError, stepStatus: "failed", at: finishedAt).isEmpty)
    XCTAssertEqual(state, settledState)
  }

  private func apply(_ update: AdapterActivityUpdate, to state: inout ActivityState, at updateTime: Date? = nil) -> [ActivityEventDraft] {
    ActivityReducer.apply(update, to: &state, executionId: executionId, at: updateTime ?? at)
  }

  private func planEntry(_ content: String, status: String = "pending") -> AdapterActivityPlanEntry {
    AdapterActivityPlanEntry(content: content, status: status, priority: "high")
  }
}
