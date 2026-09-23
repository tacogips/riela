import AgentGateway
import AgentGatewayAppCore
import Foundation
import XCTest
@testable import RielaAdapters

final class GatewayTurnLifetimeTests: XCTestCase {
  func testSuccessAndFailureBothAwaitConnectionCleanupBeforeReturning() async throws {
    for shouldFail in [false, true] {
      let cleaning = expectation(description: "cleanup entered")
      let gate = AsyncStream<Void>.makeStream()
      let state = LifetimeReturnState()
      let operation = Task {
        defer { state.markReturned() }
        return try await withGatewayTurnLifetime(cleanup: {
          cleaning.fulfill()
          for await _ in gate.stream { break }
        }, operation: {
          if shouldFail { throw POSIXError(.EIO) }
          return "terminal result"
        })
      }
      await fulfillment(of: [cleaning], timeout: 2)
      XCTAssertFalse(state.returned, "Returning a node must not race an unstructured cleanup Task")
      gate.continuation.finish()
      let result = await operation.result
      if shouldFail {
        guard case .failure = result else { return XCTFail("Expected original failure") }
      } else {
        XCTAssertEqual(try result.get(), "terminal result")
      }
      XCTAssertTrue(state.returned)
    }
  }

  func testTurnClosureCancelsAndJoinsExecutorCleanupAndRejectsLateLaunch() async throws {
    let started = expectation(description: "executor started")
    let cleaning = expectation(description: "executor cleanup entered")
    let release = AsyncStream<Void>.makeStream()
    let base = BarrierGatewayExecutor(started: started, cleaning: cleaning, release: release.stream)
    let executor = GatewayTurnExecutor(base: base)
    let params = GatewayExecuteParams(vendor: .codex, model: "fixture", prompt: "fixture")
    let invocation = Task { try await executor.execute(params, emit: { _ in }) }
    await fulfillment(of: [started], timeout: 2)
    let state = LifetimeReturnState()
    let closing = Task {
      await executor.finish()
      state.markReturned()
    }
    await fulfillment(of: [cleaning], timeout: 2)
    XCTAssertFalse(state.returned)
    release.continuation.finish()
    await closing.value
    guard case .failure = await invocation.result else { return XCTFail("Closed turn must cancel its executor") }
    do {
      _ = try await executor.execute(params, emit: { _ in })
      XCTFail("A disconnected turn must reject a queued late execute")
    } catch is CancellationError {
      // Closed scope cannot create another process.
    }
  }
}

private final class LifetimeReturnState: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  var returned: Bool { lock.withLock { value } }
  func markReturned() { lock.withLock { value = true } }
}

private struct BarrierGatewayExecutor: GatewayExecuting {
  let started: XCTestExpectation
  let cleaning: XCTestExpectation
  let release: AsyncStream<Void>

  func execute(_ params: GatewayExecuteParams, emit: @escaping GatewayEventEmitter) async throws -> GatewayExecuteResult {
    started.fulfill()
    do {
      try await Task.sleep(for: .seconds(5))
    } catch {
      cleaning.fulfill()
      // Cleanup belongs to the executor and cannot be abandoned by its caller.
      await Task {
        for await _ in release { break }
      }.value
      throw error
    }
    throw POSIXError(.ETIMEDOUT)
  }
}
