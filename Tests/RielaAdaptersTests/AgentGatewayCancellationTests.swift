import ACP
import AgentGateway
import AgentGatewayAppCore
import Foundation
import Testing
@testable import RielaAdapters
@testable import RielaCore

private final class CancellationGatewayExecutor: GatewayExecuting, @unchecked Sendable {
  enum Outcome: Sendable {
    case waitForCancellation
    case gatewayFailureAfterCancellation
    case vendorCancellation
  }

  private let outcome: Outcome
  private let startedContinuation: AsyncStream<Void>.Continuation
  let started: AsyncStream<Void>

  init(outcome: Outcome) {
    self.outcome = outcome
    let stream = AsyncStream<Void>.makeStream()
    started = stream.stream
    startedContinuation = stream.continuation
  }

  func execute(
    _ params: GatewayExecuteParams,
    emit: @escaping GatewayEventEmitter
  ) async throws -> GatewayExecuteResult {
    startedContinuation.yield()
    switch outcome {
    case .waitForCancellation:
      try await Task.sleep(for: .seconds(30))
    case .gatewayFailureAfterCancellation:
      do {
        try await Task.sleep(for: .seconds(30))
      } catch {
        throw GatewayRPCError(code: -32603, message: "cancelled vendor request")
      }
    case .vendorCancellation:
      throw CancellationError()
    }
    return GatewayExecuteResult(vendor: params.vendor, model: params.model, text: "unexpected")
  }

  func waitUntilStarted() async {
    var iterator = started.makeAsyncIterator()
    _ = await iterator.next()
  }
}

@Test func hostCancellationThrowsCancellationErrorFromGatewayAdapter() async throws {
  let executor = CancellationGatewayExecutor(outcome: .waitForCancellation)
  let adapter = AgentGatewayNodeAdapter(executorFactory: { _ in executor })
  let task = Task {
    try await adapter.execute(
      AdapterExecutionInput(
        node: AgentNodePayload(id: "worker", executionBackend: .codexAgent, model: "fixture"),
        promptText: "prompt"
      ),
      context: AdapterExecutionContext()
    )
  }

  await executor.waitUntilStarted()
  task.cancel()
  do {
    _ = try await task.value
    Issue.record("expected host cancellation")
  } catch is CancellationError {
    #expect(true)
  } catch {
    Issue.record("expected CancellationError, got \(error)")
  }
}

@Test func hostCancellationDominatesGatewayACPError() async throws {
  let executor = CancellationGatewayExecutor(outcome: .gatewayFailureAfterCancellation)
  let adapter = AgentGatewayNodeAdapter(executorFactory: { _ in executor })
  let task = Task {
    try await adapter.execute(
      AdapterExecutionInput(
        node: AgentNodePayload(id: "worker", executionBackend: .codexAgent, model: "fixture"),
        promptText: "prompt"
      ),
      context: AdapterExecutionContext()
    )
  }

  await executor.waitUntilStarted()
  task.cancel()
  do {
    _ = try await task.value
    Issue.record("expected cancellation instead of ACP provider failure")
  } catch is CancellationError {
    #expect(true)
  } catch {
    Issue.record("expected CancellationError, got \(error)")
  }
}

@Test func cancelledTaskSkipsRetryNormalizationAndSleep() async {
  let task = Task {
    try await executeWithRetry(
      policy: RetryPolicy(maxAttempts: 3, retryDelay: .seconds(30)),
      operation: { throw AdapterExecutionError(.providerError, "retryable") },
      normalizeError: { _ in
        Issue.record("cancelled operation must bypass error normalization")
        return AdapterExecutionError(.providerError, "normalized")
      }
    ) as String
  }
  task.cancel()
  do {
    _ = try await task.value
    Issue.record("expected task cancellation")
  } catch is CancellationError {
    #expect(true)
  } catch {
    Issue.record("expected CancellationError, got \(error)")
  }
}

@Test func watchdogDeadlineStillReturnsTimeout() async {
  let executor = CancellationGatewayExecutor(outcome: .waitForCancellation)
  let adapter = AgentGatewayNodeAdapter(executorFactory: { _ in executor })
  do {
    _ = try await adapter.execute(
      AdapterExecutionInput(
        node: AgentNodePayload(id: "worker", executionBackend: .codexAgent, model: "fixture"),
        promptText: "prompt"
      ),
      context: AdapterExecutionContext(deadline: Date().addingTimeInterval(0.05))
    )
    Issue.record("expected watchdog timeout")
  } catch let error as AdapterExecutionError {
    #expect(error.code == .timeout)
  } catch {
    Issue.record("expected timeout, got \(error)")
  }
}

@Test func vendorCancellationWithoutHostCancellationKeepsProviderFailureBehavior() async {
  let executor = CancellationGatewayExecutor(outcome: .vendorCancellation)
  let adapter = AgentGatewayNodeAdapter(executorFactory: { _ in executor })
  do {
    _ = try await adapter.execute(
      AdapterExecutionInput(
        node: AgentNodePayload(id: "worker", executionBackend: .codexAgent, model: "fixture"),
        promptText: "prompt"
      ),
      context: AdapterExecutionContext()
    )
    Issue.record("expected vendor cancellation to retain existing failure behavior")
  } catch let error as AdapterExecutionError {
    #expect(error.code == .providerError)
  } catch {
    Issue.record("expected existing provider failure, got \(error)")
  }
}
