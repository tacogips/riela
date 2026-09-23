import Foundation

/// Controller and local workflow processes share a locked durable snapshot.
/// Remote workers use HTTP and never access the controller filesystem.
/// HTTP authentication must bind registration IDs/groups before calling here.
public actor DistributedJobController {
  private struct Snapshot: Codable, Equatable {
    var version = 1
    var workers: [String: DistributedWorkerRegistration] = [:]
    var jobs: [DistributedJob] = []
    var workerLastSeen: [String: Date]?
    var attachments: [String: String]?
    var archives: [String: DistributedJobArchive.Reference]?
  }

  private let storeLock: DistributedStoreLock
  private let fileURL: URL
  private let validateConfiguration: @Sendable () throws -> Void
  private let limits: DistributedStoreLimits
  private var state: Snapshot

  public init(fileURL: URL) throws {
    try self.init(fileURL: fileURL, validateConfiguration: {})
  }

  public init(fileURL: URL, validateConfiguration: @escaping @Sendable () throws -> Void) throws {
    try self.init(fileURL: fileURL, limits: .init(), validateConfiguration: validateConfiguration)
  }

  public init(fileURL: URL, limits: DistributedStoreLimits, validateConfiguration: @escaping @Sendable () throws -> Void = {}) throws {
    self.fileURL = fileURL
    self.limits = limits
    self.validateConfiguration = validateConfiguration
    storeLock = try DistributedStoreLock(url: fileURL.appendingPathExtension("lock"))
    if FileManager.default.fileExists(atPath: fileURL.path) {
      state = try JSONDecoder().decode(Snapshot.self, from: DistributedJobArchive.read(fileURL, maximumBytes: limits.maximumSnapshotBytes))
      guard state.version == 1 else { throw DistributedWorkerError.unsupportedStoreVersion }
      try Self.validateSnapshot(state, limits: limits)
    } else {
      state = Snapshot()
    }
  }

  public func register(workerId: String, groups: Set<String>, capacity: Int, now: Date = Date()) throws -> DistributedWorkerRegistration {
    return try withStoreLock {
      guard validName(workerId), groups.allSatisfy(validName), (1...1024).contains(capacity) else {
        throw DistributedWorkerError.invalidRegistration
      }
      guard state.workers[workerId] != nil || state.workers.count < 1024 else { throw DistributedWorkerError.storeCapacityExceeded }
      let registration = DistributedWorkerRegistration(
        workerId: workerId, incarnation: UUID().uuidString, groups: groups, capacity: capacity
      )
      var next = state
      // A new incarnation cannot acknowledge or inherit a previous process's work.
      for index in next.jobs.indices where next.jobs[index].status == .leased
        && next.jobs[index].lease?.workerId == workerId {
        next.jobs[index].status = .lost
      }
      next.workers[workerId] = registration
      next.workerLastSeen = next.workerLastSeen ?? [:]
      next.workerLastSeen?[workerId] = now
      try commit(next)
      return registration

    }
  }

  public func enqueue(id: String, target: DistributedWorkerTarget, payload: JSONObject) throws -> DistributedJob {
    try withStoreLock { try enqueueUnlocked(id: id, target: target, payload: payload) }
  }

  /// Keep configuration replacement and the idle check in the same transaction
  /// as enqueue/claim, including requests from independent local processes.
  public func updateConfigurationIfIdle(_ update: @Sendable () throws -> Void) throws {
    try withStoreLock {
      guard !state.jobs.contains(where: { $0.status == .queued || $0.status == .leased }) else {
        throw DistributedWorkerError.controllerBusy
      }
      try update()
    }
  }

  /// Compare and enqueue under the same cross-process lock. Reattachment may
  /// regenerate a relative timeout, but must never change the work or routing.
  public func enqueueNode(id: String, target: DistributedWorkerTarget, request: DistributedNodeRequest) throws -> DistributedJob {
    try withStoreLock { try enqueueNodeUnlocked(id: id, target: target, request: request, attachment: nil) }
  }

  public func attachNode(id: String, target: DistributedWorkerTarget, request: DistributedNodeRequest) throws -> String {
    try withStoreLock {
      let token = UUID().uuidString
      _ = try enqueueNodeUnlocked(id: id, target: target, request: request, attachment: token)
      return token
    }
  }

  private func enqueueNodeUnlocked(
    id: String, target: DistributedWorkerTarget, request: DistributedNodeRequest, attachment: String?
  ) throws -> DistributedJob {
    if let existing = try jobUnlocked(id: id) {
      let saved = try JSONDecoder().decode(DistributedNodeRequest.self, from: JSONEncoder().encode(existing.payload))
      guard existing.target == target, saved.invocation == request.invocation,
        saved.workspace == request.workspace, saved.exports == request.exports else { throw DistributedWorkerError.conflictingJob }
      if let attachment {
        var next = state
        next.attachments = next.attachments ?? [:]
        next.attachments?[id] = attachment
        try commit(next)
      }
      return existing
    }
    let payload = try JSONDecoder().decode(JSONObject.self, from: JSONEncoder().encode(request))
    return try enqueueUnlocked(id: id, target: target, payload: payload, attachment: attachment)
  }

  private func enqueueUnlocked(id: String, target: DistributedWorkerTarget, payload: JSONObject, attachment: String? = nil) throws -> DistributedJob {
    guard validName(id), target.workerId.map(validName) ?? true, target.group.map(validName) ?? true else {
      throw DistributedWorkerError.invalidJob
    }
    guard try JSONEncoder().encode(payload).count <= 1024 * 1024 else { throw DistributedWorkerError.invalidJob }
    if let existing = try jobUnlocked(id: id) {
      guard existing.target == target, existing.payload == payload else { throw DistributedWorkerError.conflictingJob }
      return existing
    }
    let activeCount = state.jobs.filter { $0.status == .queued || $0.status == .leased }.count
    let archivedBytes = (state.archives ?? [:]).values.reduce(0) { $0 + $1.size }
    let unarchivedCount = state.jobs.filter { $0.archived != true }.count
    guard state.jobs.count < limits.maximumJobs, activeCount < limits.maximumActiveJobs,
      archivedBytes + (unarchivedCount + 1) * limits.maximumJobBytes <= limits.maximumArchiveBytes else {
      throw DistributedWorkerError.storeCapacityExceeded
    }
    let job = DistributedJob(id: id, target: target, payload: payload, status: .queued)
    var next = state
    next.jobs.append(job)
    if let attachment {
      next.attachments = next.attachments ?? [:]
      next.attachments?[id] = attachment
    }
    try commit(next)
    return job

  }

  public func claim(
    worker: DistributedWorkerRegistration, now: Date, leaseDuration: TimeInterval
  ) throws -> DistributedJob? {
    return try withStoreLock {
      try validate(worker)
      try validateDuration(leaseDuration)
      var next = expiredSnapshot(now: now)
      next.workerLastSeen = next.workerLastSeen ?? [:]
      next.workerLastSeen?[worker.workerId] = now
      let running = next.jobs.filter { $0.status == .leased && $0.lease?.workerId == worker.workerId }.count
      guard running < worker.capacity,
        let index = next.jobs.firstIndex(where: { $0.status == .queued && $0.target.matches(worker) }) else {
        try commit(next)
        return nil
      }
      next.jobs[index].status = .leased
      next.jobs[index].lease = DistributedJobLease(
        workerId: worker.workerId, incarnation: worker.incarnation,
        token: UUID().uuidString, expiresAt: now.addingTimeInterval(leaseDuration)
      )
      try commit(next)
      return next.jobs[index]

    }
  }

  public func renew(
    jobId: String, worker: DistributedWorkerRegistration, token: String, now: Date, leaseDuration: TimeInterval
  ) throws {
    return try withStoreLock {
      try validate(worker)
      try validateDuration(leaseDuration)
      var next = expiredSnapshot(now: now)
      try commit(next)
      let index = try leasedIndex(jobId: jobId, worker: worker, token: token)
      next.jobs[index].lease?.expiresAt = now.addingTimeInterval(leaseDuration)
      next.workerLastSeen = next.workerLastSeen ?? [:]
      next.workerLastSeen?[worker.workerId] = now
      try commit(next)

    }
  }

  public func complete(
    jobId: String, worker: DistributedWorkerRegistration, token: String, result: DistributedJobResult, now: Date
  ) throws -> DistributedJob {
    return try withStoreLock {
      try validate(worker)
      guard try JSONEncoder().encode(result).count <= DistributedJobResult.maximumEncodedBytes else { throw DistributedWorkerError.invalidJob }
      try commit(expiredSnapshot(now: now))
      guard let index = state.jobs.firstIndex(where: { $0.id == jobId }) else { throw DistributedWorkerError.unknownJob }
      let job = try jobUnlocked(id: jobId) ?? state.jobs[index]
      guard job.lease?.workerId == worker.workerId, job.lease?.incarnation == worker.incarnation,
        job.lease?.token == token else { throw DistributedWorkerError.staleLease }
      if let previous = job.result {
        guard previous == result else { throw DistributedWorkerError.conflictingResult }
        return job
      }
      _ = try leasedIndex(jobId: jobId, worker: worker, token: token)
      let exports = (try? JSONDecoder().decode(DistributedNodeRequest.self, from: JSONEncoder().encode(job.payload)))?.exports ?? []
      try DistributedArtifact.validate(result.artifacts ?? [], expectedPaths: result.outcome == .succeeded ? exports : [])
      _ = try artifactStore.materialize(result.artifacts ?? [])
      var next = state
      next.jobs[index].status = result.outcome == .succeeded ? .succeeded : .failed
      next.jobs[index].result = result
      try commit(next)
      return next.jobs[index]

    }
  }

  public func cancel(jobId: String) throws {
    try withStoreLock { try cancelUnlocked(jobId: jobId) }
  }

  public func cancel(jobId: String, attachment: String) throws {
    try withStoreLock {
      guard state.attachments?[jobId] == attachment else { return }
      try cancelUnlocked(jobId: jobId)
    }
  }

  private func cancelUnlocked(jobId: String) throws {
    guard let index = state.jobs.firstIndex(where: { $0.id == jobId }) else { throw DistributedWorkerError.unknownJob }
    guard state.jobs[index].status == .queued || state.jobs[index].status == .leased else { return }
    var next = state
    next.jobs[index].status = .cancelled
    try commit(next)
  }

  public func appendEvents(
    jobId: String, worker: DistributedWorkerRegistration, token: String,
    events: [DistributedJobEvent], now: Date
  ) throws {
    try withStoreLock {
      try validate(worker)
      guard !events.isEmpty, events.count <= 16,
        try events.allSatisfy({ try JSONEncoder().encode($0).count <= 16 * 1024 }) else {
        throw DistributedWorkerError.invalidJob
      }
      try commit(expiredSnapshot(now: now))
      let index = try leasedIndex(jobId: jobId, worker: worker, token: token)
      var next = state
      var retained = next.jobs[index].events ?? []
      var last = next.jobs[index].eventCount ?? 0
      for event in events {
        if event.sequence <= last {
          guard retained.contains(event) else { throw DistributedWorkerError.conflictingJob }
          continue
        }
        guard event.sequence == last + 1 else { throw DistributedWorkerError.invalidJob }
        retained.append(event)
        last = event.sequence
      }
      next.jobs[index].events = Array(retained.suffix(128))
      next.jobs[index].eventCount = last
      try commit(next)
    }
  }

  public func jobs(now: Date) throws -> [DistributedJob] {
    return try withStoreLock {
      try commit(expiredSnapshot(now: now))
      return state.jobs

    }
  }

  public func job(id: String, now: Date) throws -> DistributedJob? {
    try withStoreLock {
      try commit(expiredSnapshot(now: now))
      return try jobUnlocked(id: id)
    }
  }

  private func jobUnlocked(id: String) throws -> DistributedJob? {
    guard let job = state.jobs.first(where: { $0.id == id }) else { return nil }
    guard job.archived == true else { return job }
    guard let reference = state.archives?[id] else { throw DistributedWorkerError.storeUnavailable }
    return try archive.load(reference, jobId: id)
  }

  /// Returns controller-local files only for acknowledged successful jobs.
  public func artifacts(jobId: String) throws -> [DistributedArtifactLocation] {
    try withStoreLock {
      guard let job = try jobUnlocked(id: jobId) else { throw DistributedWorkerError.unknownJob }
      guard job.status == .succeeded, let result = job.result else { return [] }
      let exports = (try? JSONDecoder().decode(DistributedNodeRequest.self, from: JSONEncoder().encode(job.payload)))?.exports ?? []
      try DistributedArtifact.validate(result.artifacts ?? [], expectedPaths: exports)
      return try artifactStore.materialize(result.artifacts ?? [])
    }
  }

  private var artifactStore: DistributedArtifactStore {
    DistributedArtifactStore(directory: fileURL.appendingPathExtension("artifacts"))
  }

  private var archive: DistributedJobArchive {
    .init(directory: fileURL.appendingPathExtension("history"), maximumJobBytes: limits.maximumJobBytes)
  }

  public func workers(now: Date, offlineAfter: TimeInterval = 30) throws -> [DistributedWorkerStatus] {
    try withStoreLock {
      try commit(expiredSnapshot(now: now))
      return state.workers.values.sorted { $0.workerId < $1.workerId }.map { worker in
        let lastSeen = state.workerLastSeen?[worker.workerId]
        return DistributedWorkerStatus(
          workerId: worker.workerId, groups: worker.groups, capacity: worker.capacity,
          activeJobIds: state.jobs.filter { $0.status == .leased && $0.lease?.workerId == worker.workerId }.map(\.id),
          lastSeenAt: lastSeen, online: lastSeen.map { now.timeIntervalSince($0) < offlineAfter } ?? false
        )
      }
    }
  }

  private func withStoreLock<T>(_ body: () throws -> T) throws -> T {
    try storeLock.acquire()
    defer { storeLock.release() }
    try validateConfiguration()
    if FileManager.default.fileExists(atPath: fileURL.path) {
      state = try JSONDecoder().decode(Snapshot.self, from: DistributedJobArchive.read(fileURL, maximumBytes: limits.maximumSnapshotBytes))
      guard state.version == 1 else { throw DistributedWorkerError.unsupportedStoreVersion }
      try Self.validateSnapshot(state, limits: limits)
    } else {
      state = Snapshot()
    }
    return try body()
  }

  private func validate(_ worker: DistributedWorkerRegistration) throws {
    guard state.workers[worker.workerId] == worker else { throw DistributedWorkerError.staleWorker }
  }

  private static func validateSnapshot(_ snapshot: Snapshot, limits: DistributedStoreLimits) throws {
    let references = snapshot.archives ?? [:]
    guard snapshot.jobs.count <= limits.maximumJobs, snapshot.workers.count <= 1024,
      references.count <= snapshot.jobs.count,
      references.values.allSatisfy({ $0.size >= 0 && $0.size <= limits.maximumJobBytes }),
      references.values.reduce(0, { $0 + $1.size }) <= limits.maximumArchiveBytes else {
      throw DistributedWorkerError.storeCapacityExceeded
    }
  }

  private func validateDuration(_ duration: TimeInterval) throws {
    guard duration.isFinite, duration > 0, duration <= 3600 else { throw DistributedWorkerError.invalidLeaseDuration }
  }

  private func leasedIndex(jobId: String, worker: DistributedWorkerRegistration, token: String) throws -> Int {
    guard let index = state.jobs.firstIndex(where: { $0.id == jobId }) else { throw DistributedWorkerError.unknownJob }
    let job = state.jobs[index]
    guard job.status == .leased, job.lease?.workerId == worker.workerId,
      job.lease?.incarnation == worker.incarnation, job.lease?.token == token else {
      throw DistributedWorkerError.staleLease
    }
    return index
  }

  private func expiredSnapshot(now: Date) -> Snapshot {
    var next = state
    for index in next.jobs.indices where next.jobs[index].status == .leased {
      if let lease = next.jobs[index].lease, lease.expiresAt <= now {
        next.jobs[index].status = .lost
      }
    }
    return next
  }

  private func validName(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 256
      && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
      && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func commit(_ proposed: Snapshot) throws {
    var next = proposed
    let terminalIndices = next.jobs.indices.filter {
      next.jobs[$0].status != .queued && next.jobs[$0].status != .leased && next.jobs[$0].archived != true
    }
    for index in terminalIndices.dropLast(limits.retainedTerminalJobs) {
      let job = next.jobs[index]
      let reference = try archive.store(job)
      next.archives = next.archives ?? [:]
      next.archives?[job.id] = reference
      next.jobs[index] = DistributedJob(id: job.id, target: job.target, payload: [:], status: job.status, lease: job.lease, eventCount: job.eventCount)
      next.jobs[index].archived = true
      next.attachments?[job.id] = nil
    }
    guard next != state || !FileManager.default.fileExists(atPath: fileURL.path) else { return }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let bytes = try encoder.encode(next)
    guard bytes.count <= limits.maximumSnapshotBytes else { throw DistributedWorkerError.storeCapacityExceeded }
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try DistributedSnapshotWriter.write(bytes, to: fileURL)
    // Never acknowledge a mutation that could not be persisted.
    state = next
  }
}
