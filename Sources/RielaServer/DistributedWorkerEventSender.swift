import Foundation
import RielaCore

/// Serial delivery preserves backend event order even when callbacks overlap.
/// The queue is bounded; overflow or exhausted retries fails the event channel
/// explicitly rather than silently claiming that all logs were delivered.
public actor DistributedWorkerEventSender {
  private let client: DistributedWorkerHTTPClient
  private let registration: DistributedWorkerRegistration
  private let job: DistributedJob
  private var drainTask: Task<Void, Never>?
  private var queue: [DistributedJobEvent] = []
  private var sequence = 0
  private var failed = false

  public init(client: DistributedWorkerHTTPClient, registration: DistributedWorkerRegistration, job: DistributedJob) {
    self.client = client
    self.registration = registration
    self.job = job
  }

  public func record(_ event: AdapterBackendEvent) {
    guard !failed else { return }
    guard queue.count < 128 else { failed = true; return }
    sequence += 1
    queue.append(DistributedJobEvent(sequence: sequence, event: bounded(event)))
    if drainTask == nil { drainTask = Task { await drain() } }
  }

  public func finish() async throws {
    await drainTask?.value
    guard !failed else { throw AdapterExecutionError(.providerError, "remote event delivery failed") }
  }

  public func cancel() async {
    failed = true
    let task = drainTask
    task?.cancel()
    await task?.value
    queue.removeAll()
  }

  private func drain() async {
    while !failed, !queue.isEmpty { await deliver(queue.removeFirst()) }
    drainTask = nil
  }

  private func deliver(_ event: DistributedJobEvent) async {
    guard !failed, let token = job.lease?.token else { failed = true; return }
    for attempt in 0..<3 {
      do {
        try Task.checkCancellation()
        _ = try await client.send(.init(operation: .events, registration: registration, jobId: job.id, leaseToken: token, events: [event]))
        return
      } catch {
        let retryable = error as? DistributedWorkerTransportError == .networkFailure
          || error as? DistributedWorkerTransportError == .rejected(status: 503)
        guard retryable, attempt < 2 else { failed = true; return }
        do { try await Task.sleep(for: .milliseconds(250)) } catch { failed = true; return }
      }
    }
  }

  private func bounded(_ event: AdapterBackendEvent) -> AdapterBackendEvent {
    if let data = try? JSONEncoder().encode(event), data.count <= 15 * 1024 { return event }
    let truncated = AdapterBackendEvent(
      provider: bytePrefix(event.provider, limit: 128), eventType: "remote.event_truncated", channel: .lifecycle,
      contentSnapshot: bytePrefix(event.contentSnapshot ?? event.contentDelta ?? "", limit: 2048),
      metadata: ["originalEventType": .string(bytePrefix(event.eventType, limit: 128))]
    )
    if let data = try? JSONEncoder().encode(truncated), data.count <= 15 * 1024 { return truncated }
    return AdapterBackendEvent(provider: "worker", eventType: "remote.event_truncated", channel: .lifecycle)
  }

  private func bytePrefix(_ text: String, limit: Int) -> String {
    // A grapheme can contain arbitrarily many combining scalars. Bound bytes,
    // then revalidate JSON size above because escaping can expand the payload.
    var result = ""
    var byteCount = 0
    for scalar in text.unicodeScalars {
      let count = scalar.utf8.count
      guard byteCount + count <= limit else { break }
      result.unicodeScalars.append(scalar)
      byteCount += count
    }
    return result
  }
}
