import Foundation

public final class AgentProcessRegistry<Managed>: @unchecked Sendable {
  private let lock = NSLock()
  private var records: [String: AgentProcessRecord] = [:]
  private var managedProcesses: [String: Managed] = [:]
  private var nextPid: Int32

  public init(nextPid: Int32 = 10_000) {
    self.nextPid = nextPid
  }

  public func list() -> [AgentProcessRecord] {
    lock.lock()
    defer { lock.unlock() }
    return records.values.sorted { $0.startedAt < $1.startedAt }
  }

  public func get(id: String) -> AgentProcessRecord? {
    lock.lock()
    defer { lock.unlock() }
    return records[id]
  }

  public func store(record: AgentProcessRecord, managed: Managed? = nil) {
    lock.lock()
    records[record.id] = record
    if let managed {
      managedProcesses[record.id] = managed
    }
    lock.unlock()
  }

  public func createVirtualRunningRecord(commandArguments: [String], prompt: String) -> AgentProcessRecord {
    lock.lock()
    let pid = nextPid
    nextPid += 1
    let record = Self.makeRecord(
      pid: pid,
      commandArguments: commandArguments,
      prompt: prompt,
      status: .running
    )
    records[record.id] = record
    lock.unlock()
    return record
  }

  public static func makeRecord(
    id: String = UUID().uuidString,
    pid: Int32,
    commandArguments: [String],
    prompt: String,
    status: AgentProcessStatus,
    exitCode: Int32? = nil
  ) -> AgentProcessRecord {
    AgentProcessRecord(
      id: id,
      pid: pid,
      command: commandArguments.joined(separator: " "),
      prompt: prompt,
      startedAt: agentRuntimeISO8601Now(),
      status: status,
      exitCode: exitCode,
      arguments: commandArguments
    )
  }

  public func markKilled(id: String) -> (marked: Bool, managed: Managed?) {
    lock.lock()
    guard var record = records[id], record.status == .running else {
      lock.unlock()
      return (false, nil)
    }
    let managed = managedProcesses[id]
    record.status = .killed
    records[id] = record
    lock.unlock()
    return (true, managed)
  }

  public func appendInput(id: String, text: String) -> (appended: Bool, managed: Managed?) {
    lock.lock()
    guard var record = records[id], record.status == .running else {
      lock.unlock()
      return (false, nil)
    }
    let managed = managedProcesses[id]
    record.input.append(text)
    records[id] = record
    lock.unlock()
    return (true, managed)
  }

  public func markAllRunningKilled() -> [Managed] {
    lock.lock()
    let running = managedProcesses.filter { id, _ in
      records[id]?.status == .running
    }.map(\.value)
    records = records.mapValues { record in
      var next = record
      if next.status == .running {
        next.status = .killed
      }
      return next
    }
    lock.unlock()
    return running
  }

  @discardableResult
  public func prune() -> Int {
    lock.lock()
    let before = records.count
    records = records.filter { $0.value.status == .running }
    let removed = before - records.count
    lock.unlock()
    return removed
  }

  @discardableResult
  public func finish(id: String, exitCode: Int32) -> AgentProcessRecord? {
    lock.lock()
    guard var record = records[id] else {
      lock.unlock()
      return nil
    }
    if record.status == .running {
      record.status = .exited
    }
    record.exitCode = exitCode
    records[id] = record
    lock.unlock()
    return record
  }

  public func removeManagedProcess(id: String) {
    lock.lock()
    managedProcesses.removeValue(forKey: id)
    lock.unlock()
  }
}
