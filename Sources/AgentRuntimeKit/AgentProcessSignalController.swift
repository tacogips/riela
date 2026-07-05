import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

typealias AgentProcessSignal = @Sendable (pid_t, Int32) -> Int32

final class AgentProcessSignalController: @unchecked Sendable {
  private let lock = NSLock()
  private weak var process: Process?
  private let signalProcess: AgentProcessSignal
  private var processId: pid_t?
  private var processGroupId: pid_t?
  private var killWorkItem: DispatchWorkItem?

  init(
    process: Process?,
    signalProcess: @escaping AgentProcessSignal = { processId, signal in kill(processId, signal) }
  ) {
    self.process = process
    self.signalProcess = signalProcess
    guard let process else {
      return
    }
    let processId = process.processIdentifier
    self.processId = processId
    if setpgid(processId, processId) == 0 {
      self.processGroupId = processId
    }
  }

  @discardableResult
  func terminateAndScheduleKill(after delay: TimeInterval) -> Bool {
    let signaled = signalGroupOrProcess(SIGTERM)
    guard signaled else {
      return false
    }
    scheduleKillIfRunning(after: delay)
    return true
  }

  func markExited() {
    lock.lock()
    processId = nil
    processGroupId = nil
    let workItem = killWorkItem
    killWorkItem = nil
    lock.unlock()
    workItem?.cancel()
  }

  @discardableResult
  private func scheduleKillIfRunning(after delay: TimeInterval) -> Bool {
    let workItem = DispatchWorkItem { [weak self] in
      self?.killScheduledProcess()
    }
    lock.lock()
    guard processId != nil else {
      lock.unlock()
      workItem.cancel()
      return false
    }
    killWorkItem?.cancel()
    killWorkItem = workItem
    lock.unlock()

    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: workItem)
    return true
  }

  private func killScheduledProcess() {
    lock.lock()
    let shouldKill = processId != nil
    lock.unlock()
    guard shouldKill else {
      markExited()
      return
    }
    if !signalGroupOrProcess(SIGKILL) {
      markExited()
    }
  }

  @discardableResult
  private func signalGroupOrProcess(_ signal: Int32) -> Bool {
    lock.lock()
    let groupId = processGroupId
    let processId = self.processId
    lock.unlock()

    if let groupId, signalProcess(-groupId, signal) == 0 {
      return true
    }
    if let processId, signalProcess(processId, signal) == 0 {
      return true
    }
    return false
  }
}
