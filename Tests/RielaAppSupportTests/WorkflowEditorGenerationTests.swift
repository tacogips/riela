import Foundation
import RielaAppSupport
import RielaCore
import XCTest

final class WorkflowEditorGenerationTests: XCTestCase {
  private let definition: JSONObject = ["workflowId": .string("test"), "nodes": .array([]), "steps": .array([])]
  func testBufferedProviderRoundsExposeGraphBeforeNextRoundCompletes() async throws {
    let store = WorkflowEditorGenerationStore()
    let gate = GenerationGate()
    let initial = definition
    let started = try await store.start(profile: "alpha", definition: initial) { handler in
      try await WorkflowEditorAuthoringRounds.run(initial: initial, handler: handler) { current, index, events in
        if index == 0 {
          let text = #"{"type":"definition","definition":{"workflowId":"test","nodes":[{"id":"a"}],"steps":[{"id":"a","nodeId":"a"}]}}"#
            + "\n" + #"{"type":"continue","value":true}"#
          await events(AdapterBackendEvent(provider: "buffered", eventType: "message", channel: .assistant, contentSnapshot: text))
          return "An extracted adapter summary without the protocol"
        }
        XCTAssertEqual(current["steps"], .array([.object(["id": .string("a"), "nodeId": .string("a")])]))
        await gate.wait()
        return #"{"type":"definition","definition":{"workflowId":"test","nodes":[{"id":"a"},{"id":"b"}],"steps":[{"id":"a","nodeId":"a"},{"id":"b","nodeId":"b"}]}}"#
          + "\n" + #"{"type":"continue","value":false}"#
      }
    }
    let intermediate = try await waitFor(store, id: started.id) { $0.revision == 1 }
    XCTAssertEqual(intermediate.status, .running)
    guard case let .array(steps)? = intermediate.definition["steps"] else { return XCTFail("Missing intermediate graph") }
    XCTAssertEqual(steps.count, 1)
    await gate.release()
    let final = try await waitFor(store, id: started.id) { $0.status == .completed }
    XCTAssertEqual(final.revision, 2)
  }

  func testRoundsRejectMissingContinuationProtocol() async {
    do {
      _ = try await WorkflowEditorAuthoringRounds.run(initial: definition, handler: { _ in }, round: { _, _, _ in
        #"{"type":"message","text":"Not a framed editing round"}"#
      })
      XCTFail("Unframed buffered output must not be labeled a completed generation")
    } catch {
      XCTAssertTrue(error is WorkflowEditorAuthoringRounds.AuthoringError)
    }
  }

  func testRepeatedDefinitionIsARealRevisionNotADuplicate() async throws {
    let store = WorkflowEditorGenerationStore()
    let first = #"{"type":"definition","definition":{"workflowId":"A","nodes":[],"steps":[]}}"#
    let second = #"{"type":"definition","definition":{"workflowId":"B","nodes":[],"steps":[]}}"#
    let started = try await store.start(profile: "alpha", definition: definition) { handler in
      let transcript = [first, second, first].joined(separator: "\n") + "\n"
      await handler(AdapterBackendEvent(provider: "test", eventType: "text", channel: .assistant, contentDelta: transcript, isDelta: true))
      return transcript
    }
    let result = try await waitFor(store, id: started.id) { $0.status == .completed }
    XCTAssertEqual(result.definition["workflowId"], .string("A"))
    XCTAssertEqual(result.revision, 3)
  }

  func testStreamsIntermediateDefinitionBeforeCompletionAndIsolatesProfiles() async throws {
    let store = WorkflowEditorGenerationStore()
    let gate = GenerationGate()
    let line = "{\"type\":\"definition\",\"definition\":{\"workflowId\":\"updated\",\"nodes\":[],\"steps\":[]}}\n"
    let started = try await store.start(profile: "alpha", definition: definition) { handler in
      let middle = line.index(line.startIndex, offsetBy: 20)
      await handler(AdapterBackendEvent(provider: "test", eventType: "text", channel: .assistant, contentDelta: String(line[..<middle]), isDelta: true))
      await handler(AdapterBackendEvent(provider: "test", eventType: "text", channel: .assistant, contentDelta: String(line[middle...]), isDelta: true))
      await gate.wait()
      return line
    }
    let streamed = try await waitFor(store, id: started.id) { $0.revision == 1 }
    XCTAssertEqual(streamed.status, .running)
    XCTAssertEqual(streamed.definition["workflowId"], .string("updated"))
    let foreign = await store.snapshot(id: started.id, profile: "beta")
    XCTAssertNil(foreign)
    await gate.release()
    let completed = try await waitFor(store, id: started.id) { $0.status == .completed }
    XCTAssertEqual(completed.revision, 1, "Final replay must not duplicate streamed records")
  }

  func testCancellationRejectsLateProviderOutput() async throws {
    let store = WorkflowEditorGenerationStore()
    let gate = GenerationGate()
    let started = try await store.start(profile: "alpha", definition: definition) { _ in
      await gate.wait()
      return "{\"type\":\"message\",\"text\":\"late\"}"
    }
    let stopped = await store.cancel(id: started.id, profile: "alpha")
    XCTAssertEqual(stopped?.status, .cancelled)
    await gate.release()
    let snapshot = await store.snapshot(id: started.id, profile: "alpha")
    XCTAssertEqual(snapshot?.messages, [])
  }

  func testShutdownCancelsAllProfilesAndPreservesCompletedGenerations() async throws {
    let store = WorkflowEditorGenerationStore()
    let completed = try await store.start(profile: "alpha", definition: definition) { _ in
      "{\"type\":\"message\",\"text\":\"done\"}"
    }
    _ = try await waitFor(store, id: completed.id) { $0.status == .completed }
    let gate = GenerationGate()
    let active = try await store.start(profile: "beta", definition: definition) { _ in
      await gate.wait()
      return "{\"type\":\"message\",\"text\":\"late\"}"
    }
    await store.cancelAll()
    let stopped = await store.snapshot(id: active.id, profile: "beta")
    let retained = await store.snapshot(id: completed.id, profile: "alpha")
    XCTAssertEqual(stopped?.status, .cancelled)
    XCTAssertEqual(retained?.status, .completed)
    await gate.release()
  }

  func testIgnoresThinkingAndReportsInvalidOutput() async throws {
    let store = WorkflowEditorGenerationStore()
    let started = try await store.start(profile: "alpha", definition: definition) { handler in
      await handler(AdapterBackendEvent(provider: "test", eventType: "text", channel: .thinking,
        contentDelta: "{\"type\":\"message\",\"text\":\"private\"}\n", isDelta: true))
      return "not editor JSON"
    }
    let snapshot = try await waitFor(store, id: started.id) { $0.status == .failed }
    XCTAssertEqual(snapshot.messages, [])
    XCTAssertEqual(snapshot.definition, definition)
    XCTAssertNotNil(snapshot.error)
  }

  private func waitFor(
    _ store: WorkflowEditorGenerationStore,
    id: String,
    predicate: (WorkflowEditorGenerationSnapshot) -> Bool
  ) async throws -> WorkflowEditorGenerationSnapshot {
    for _ in 0..<100 {
      if let snapshot = await store.snapshot(id: id, profile: "alpha"), predicate(snapshot) { return snapshot }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw GenerationTestError.timeout
  }
}

private enum GenerationTestError: Error { case timeout }

private actor GenerationGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var released = false
  func wait() async {
    if released { return }
    await withCheckedContinuation { continuation = $0 }
  }
  func release() {
    released = true
    continuation?.resume()
    continuation = nil
  }
}
