import Foundation
import RielaServer

struct EventAdmissionClosed: Error {}

actor EventAdmissionGate {
  private let clock: any EventServeClock
  private var open = true
  private var running = 0
  private var queued = 0
  private var closedRequestId: String?
  private var leaseToken = 0

  init(clock: any EventServeClock) {
    self.clock = clock
  }

  var isClosed: Bool { !open }

  func admit() throws {
    guard open else { throw EventAdmissionClosed() }
    running += 1
  }

  func admitQueued() throws {
    queued = max(0, queued - 1)
    try admit()
  }

  func release() { running = max(0, running - 1) }

  func noteQueued(_ delta: Int) { queued = max(0, queued + delta) }

  func close(requestId: String, leaseSeconds: Int) -> WorkflowServeAdmissionAcknowledgement {
    open = false
    closedRequestId = requestId
    leaseToken += 1
    let token = leaseToken
    Task.detached { [clock, weak self] in
      do {
        try await clock.sleep(for: .seconds(leaseSeconds))
        await self?.expire(token: token)
      } catch {
        return
      }
    }
    return acknowledgement(requestId: requestId, state: .closed)
  }

  func confirm(requestId: String) -> WorkflowServeAdmissionAcknowledgement {
    acknowledgement(requestId: requestId, state: !open && closedRequestId == requestId ? .closed : .expired)
  }

  func reopen(requestId: String) -> WorkflowServeAdmissionAcknowledgement {
    open = true
    closedRequestId = nil
    leaseToken += 1
    return acknowledgement(requestId: requestId, state: .open)
  }

  private func expire(token: Int) {
    guard token == leaseToken, !open else { return }
    open = true
    closedRequestId = nil
    RuntimeEnvironmentChannelDescriptors.reportSafeCode("admission_lease_expired")
  }

  private func acknowledgement(requestId: String, state: WorkflowServeAdmissionState) -> WorkflowServeAdmissionAcknowledgement {
    WorkflowServeAdmissionAcknowledgement(requestId: requestId, state: state, running: running, queued: queued)
  }
}
