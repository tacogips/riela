import Foundation
import RielaCore

/// Outbound-only worker lifecycle. The invocation executor owns local process
/// cancellation; it must not return until its child processes have stopped.
public struct DistributedWorkerLoop: Sendable {
  public typealias Executor = @Sendable (DistributedJob) async throws -> DistributedJobResult
  public typealias ContextualExecutor = @Sendable (DistributedJob, DistributedWorkerRegistration) async throws -> DistributedJobResult
  private let client: DistributedWorkerHTTPClient
  private let capacity: Int
  private let capabilities: [BackendCapability]
  private let environment: [String: Bool]
  private let addonExecutables: [String: Bool]
  private let executor: ContextualExecutor

  public init(
    client: DistributedWorkerHTTPClient,
    capacity: Int,
    capabilities: [BackendCapability] = [],
    environment: [String: Bool] = [:],
    addonExecutables: [String: Bool] = [:],
    executor: @escaping Executor
  ) throws {
    guard (1...1024).contains(capacity) else { throw DistributedWorkerTransportError.invalidConfiguration }
    self.client = client
    self.capacity = capacity
    self.capabilities = capabilities
    self.environment = environment
    self.addonExecutables = addonExecutables
    self.executor = { job, _ in try await executor(job) }
  }

  public init(
    client: DistributedWorkerHTTPClient,
    capacity: Int,
    capabilities: [BackendCapability] = [],
    environment: [String: Bool] = [:],
    addonExecutables: [String: Bool] = [:],
    contextualExecutor: @escaping ContextualExecutor
  ) throws {
    guard (1...1024).contains(capacity) else { throw DistributedWorkerTransportError.invalidConfiguration }
    self.client = client
    self.capacity = capacity
    self.capabilities = capabilities
    self.environment = environment
    self.addonExecutables = addonExecutables
    self.executor = contextualExecutor
  }

  /// Register only once per process lifecycle. Transient network errors retry
  /// with the same incarnation; silently re-registering would abandon live work.
  public func run() async throws {
    let response = try await retryNetwork {
      try await client.send(.init(
        operation: .register,
        capacity: capacity,
        capabilities: capabilities,
        environment: environment,
        addonExecutables: addonExecutables
      ))
    }
    guard let registration = response.registration else { throw DistributedWorkerTransportError.invalidResponse }
    try await withThrowingTaskGroup(of: Void.self) { group in
      defer { group.cancelAll() }
      for _ in 0..<capacity {
        group.addTask { try await lane(registration: registration) }
      }
      while try await group.next() != nil {}
    }
  }

  private func lane(registration: DistributedWorkerRegistration) async throws {
    while !Task.isCancelled {
      let (response, claimStarted) = try await retryNetwork {
        let started = ContinuousClock().now
        return try await (client.send(.init(operation: .claim, registration: registration)), started)
      }
      guard let job = response.job else {
        try await Task.sleep(for: .seconds(1))
        continue
      }
      guard let lease = job.lease, lease.workerId == registration.workerId,
        lease.incarnation == registration.incarnation,
        response.leaseDurationSeconds.isFinite, response.leaseDurationSeconds >= 3,
        response.leaseDurationSeconds <= 3600 else { throw DistributedWorkerTransportError.invalidResponse }
      do {
        try await execute(job, registration: registration, lease: lease, duration: response.leaseDurationSeconds, claimStarted: claimStarted)
      } catch DistributedWorkerError.staleLease {
        // Cancellation or lease loss ends this invocation, not other capacity
        // lanes. The structured execution group has already stopped its work.
        try Task.checkCancellation()
      } catch DistributedWorkerTransportError.rejected(status: 409) {
        try Task.checkCancellation()
        // If the registration itself was fenced, the next claim will reject
        // it and terminate the worker. Never silently re-register live work.
      }
    }
    try Task.checkCancellation()
  }

  private func execute(
    _ job: DistributedJob, registration: DistributedWorkerRegistration, lease: DistributedJobLease,
    duration: Double, claimStarted: ContinuousClock.Instant
  ) async throws {
    guard ContinuousClock().now < claimStarted.advanced(by: .seconds(duration)) else {
      throw DistributedWorkerError.staleLease
    }
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        let result: DistributedJobResult
        do {
          let output = try await executor(job, registration)
          guard try JSONEncoder().encode(output).count <= DistributedJobResult.maximumEncodedBytes else {
            throw AdapterExecutionError(.invalidOutput, "worker result exceeds completion size limit")
          }
          result = output
        } catch is CancellationError { throw CancellationError() } catch let error as AdapterExecutionError {
          result = DistributedJobResult(outcome: .failed, payload: [:], failure: .init(code: error.code))
        } catch {
          // Executors return structured diagnostics themselves; arbitrary error
          // descriptions can expose local credentials and filesystem paths.
          result = DistributedJobResult(outcome: .failed, payload: [:], failure: .init(code: .providerError))
        }
        try Task.checkCancellation()
        _ = try await retryNetwork {
          try await client.send(.init(operation: .complete, registration: registration, jobId: job.id, leaseToken: lease.token, result: result))
        }
      }
      group.addTask {
        let clock = ContinuousClock()
        var renewalDeadline = claimStarted.advanced(by: .seconds(duration))
        while true {
          try await clock.sleep(until: min(clock.now.advanced(by: .seconds(duration / 3)), renewalDeadline))
          guard clock.now < renewalDeadline else { throw DistributedWorkerError.staleLease }
          let renewalStarted = clock.now
          // Stop the executor if the last acknowledged lease can no longer be
          // trusted. The controller also fences results with its own clock.
          try await withThrowingTaskGroup(of: Void.self) { renewal in
            renewal.addTask {
              _ = try await retryNetwork {
                try await client.send(.init(operation: .renew, registration: registration, jobId: job.id, leaseToken: lease.token))
              }
            }
            let deadline = renewalDeadline
            renewal.addTask {
              try await clock.sleep(until: deadline)
              throw DistributedWorkerError.staleLease
            }
            defer { renewal.cancelAll() }
            _ = try await renewal.next()
          }
          renewalDeadline = renewalStarted.advanced(by: .seconds(duration))
        }
      }
      defer { group.cancelAll() }
      _ = try await group.next()
    }
  }

  private func retryNetwork<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
    while true {
      try Task.checkCancellation()
      do { return try await operation() } catch DistributedWorkerTransportError.networkFailure {
        try await Task.sleep(for: .seconds(1))
      } catch DistributedWorkerTransportError.rejected(status: 503) {
        try await Task.sleep(for: .seconds(1))
      }
    }
  }
}
