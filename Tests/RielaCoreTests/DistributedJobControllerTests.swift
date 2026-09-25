import Foundation
import XCTest
@testable import RielaCore

final class DistributedJobControllerTests: XCTestCase {
  func testStartedRemoteExecutionCannotUseEmptyControllerAsStopProof() async throws {
    let url = try storeURL()
    let runtimeRoot = url.deletingLastPathComponent().path
    let controller = try DistributedJobController(fileURL: url)
    let now = Date()
    let execution = WorkflowStepExecution(
      executionId: "execution", stepId: "remote-step", nodeId: "remote-node",
      attempt: 1, status: .failed, createdAt: now, updatedAt: now
    )
    let session = WorkflowSession(
      workflowId: "remote-workflow", sessionId: "owned-session", status: .failed,
      entryStepId: "remote-step", createdAt: now, updatedAt: now,
      executions: [execution], failureKind: .cancelled
    )
    try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: runtimeRoot).save(
      WorkflowRuntimePersistenceSnapshot(session: session)
    )
    let remoteSteps: [String: Set<String>] = ["remote-workflow": ["remote-step"]]
    let missingProof = try await controller.provesCancellationStopped(
      sessionId: session.sessionId, runtimeRoot: runtimeRoot, now: now, remoteSteps: remoteSteps
    )
    XCTAssertFalse(missingProof)
    _ = try await controller.enqueue(id: "owned-session/execution", target: .init(), payload: [:])
    try await controller.cancel(jobId: "owned-session/execution")
    let queuedProof = try await controller.provesCancellationStopped(
      sessionId: session.sessionId, runtimeRoot: runtimeRoot, now: now, remoteSteps: remoteSteps
    )
    XCTAssertTrue(queuedProof)
  }

  func testCancellationProofRequiresWorkerStopAndSurvivesReopen() async throws {
    let url = try storeURL()
    let controller = try DistributedJobController(fileURL: url)
    let worker = try await controller.register(workerId: "worker", groups: [], capacity: 1)
    _ = try await controller.enqueue(id: "owned-session/execution", target: .init(), payload: [:])
    let claim = try await controller.claim(worker: worker, now: Date(), leaseDuration: 10)
    let claimed = try XCTUnwrap(claim)
    try await controller.cancel(jobId: claimed.id)
    let pendingProof = try await controller.provesCancellationStopped(
      sessionId: "owned-session", runtimeRoot: url.deletingLastPathComponent().path, now: Date()
    )
    XCTAssertFalse(pendingProof)
    let afterLeaseAndHeartbeat = Date().addingTimeInterval(3_600)
    let offline = try await controller.workers(now: afterLeaseAndHeartbeat).first
    XCTAssertEqual(offline?.online, false)
    let expiredJob = try await controller.job(id: claimed.id, now: afterLeaseAndHeartbeat)
    XCTAssertEqual(expiredJob?.status, .cancelled)
    XCTAssertNotNil(expiredJob?.lease)
    XCTAssertNil(expiredJob?.stoppedAt)
    let proofAfterLoss = try await controller.provesCancellationStopped(
      sessionId: "owned-session", runtimeRoot: url.deletingLastPathComponent().path, now: afterLeaseAndHeartbeat
    )
    XCTAssertFalse(proofAfterLoss)
    _ = try await controller.acknowledgeStopped(
      jobId: claimed.id, worker: worker, token: XCTUnwrap(claimed.lease?.token), now: Date()
    )
    let reopened = try DistributedJobController(fileURL: url)
    let stoppedProof = try await reopened.provesCancellationStopped(
      sessionId: "owned-session", runtimeRoot: url.deletingLastPathComponent().path, now: Date()
    )
    XCTAssertTrue(stoppedProof)
  }

  func testStaleExecutorCancellationCannotCancelReattachedExecution() async throws {
    let url = try storeURL()
    let controller = try DistributedJobController(fileURL: url)
    let executor = QueuedDistributedNodeExecutor(controller: controller)
    let invocation = DistributedNodeInvocation.adapter(.init(node: .init(id: "node", model: "local"), promptText: "work"))
    let placement = DistributedExecutionPlacement(target: .init(), workspace: "project")
    let older = Task { try await executor.execute(invocation, executionId: "reattach", placement: placement,
      context: .init(deadline: Date().addingTimeInterval(5))) }
    defer { older.cancel() }
    let deadline = Date().addingTimeInterval(3)
    while try await controller.jobs(now: Date()).isEmpty, Date() < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let worker = try await controller.register(workerId: "worker", groups: [], capacity: 1)
    let claimed = try await controller.claim(worker: worker, now: Date(), leaseDuration: 10)
    let job = try XCTUnwrap(claimed)
    let reattached = expectation(description: "new executor attached and observed lease")
    let newerController = try DistributedJobController(fileURL: url)
    let newer = Task { try await QueuedDistributedNodeExecutor(controller: newerController).execute(
      invocation, executionId: "reattach", placement: placement, context: .init(deadline: Date().addingTimeInterval(5),
        backendEventHandler: { if $0.eventType == "remote.assignment" { reattached.fulfill() } })
    ) }
    defer { newer.cancel() }
    await fulfillment(of: [reattached], timeout: 3)
    older.cancel()
    _ = try? await older.value
    let jobs = try await controller.jobs(now: Date())
    XCTAssertEqual(jobs.first?.status, .leased)
    let output = DistributedNodeOutput.adapter(.init(provider: "test", model: "local", promptText: "", completionPassed: true, payload: [:]))
    let payload = try JSONDecoder().decode(JSONObject.self, from: JSONEncoder().encode(output))
    _ = try await controller.complete(jobId: job.id, worker: worker, token: XCTUnwrap(job.lease?.token),
      result: .init(outcome: .succeeded, payload: payload), now: Date())
    let received = try await newer.value
    XCTAssertEqual(received, output)
  }

  func testCurrentAttachmentCancellationSurvivesRestartAndFencesLease() async throws {
    let url = try storeURL()
    let controller = try DistributedJobController(fileURL: url)
    let request = DistributedNodeRequest(invocation: .adapter(.init(node: .init(id: "node", model: "local"), promptText: "work")),
      workspace: "project", timeoutSeconds: 10)
    let token = try await controller.attachNode(id: "cancel", target: .init(), request: request)
    let worker = try await controller.register(workerId: "worker", groups: [], capacity: 1)
    let claimed = try await controller.claim(worker: worker, now: Date(), leaseDuration: 10)
    let job = try XCTUnwrap(claimed)
    let reopened = try DistributedJobController(fileURL: url)
    try await reopened.cancel(jobId: "cancel", attachment: token)
    do {
      _ = try await controller.renew(jobId: job.id, worker: worker, token: XCTUnwrap(job.lease?.token), now: Date(), leaseDuration: 10)
      XCTFail("Current attachment cancellation must fence the worker lease")
    } catch { XCTAssertEqual(error as? DistributedWorkerError, .staleLease) }
  }

  func testCancelledWorkerStopReceiptRequiresOriginalLeaseAndSurvivesReopen() async throws {
    let url = try storeURL()
    let controller = try DistributedJobController(fileURL: url)
    let worker = try await controller.register(workerId: "worker", groups: [], capacity: 1)
    let foreign = try await controller.register(workerId: "foreign", groups: [], capacity: 1)
    _ = try await controller.enqueue(id: "claimed", target: .init(), payload: [:])
    let claim = try await controller.claim(worker: worker, now: Date(), leaseDuration: 10)
    let claimed = try XCTUnwrap(claim)
    let lease = try XCTUnwrap(claimed.lease)
    try await controller.cancel(jobId: claimed.id)
    let pendingStop = try await controller.job(id: claimed.id, now: Date())
    XCTAssertNil(pendingStop?.stoppedAt)
    do {
      _ = try await controller.acknowledgeStopped(jobId: claimed.id, worker: foreign, token: lease.token, now: Date())
      XCTFail("Foreign worker supplied stop proof")
    } catch { XCTAssertEqual(error as? DistributedWorkerError, .staleLease) }
    do {
      _ = try await controller.acknowledgeStopped(jobId: claimed.id, worker: worker, token: "stale", now: Date())
      XCTFail("Stale lease supplied stop proof")
    } catch { XCTAssertEqual(error as? DistributedWorkerError, .staleLease) }
    let stopped = try await controller.acknowledgeStopped(
      jobId: claimed.id, worker: worker, token: lease.token, now: Date()
    )
    XCTAssertNotNil(stopped.stoppedAt)
    let reopened = try DistributedJobController(fileURL: url)
    let replay = try await reopened.acknowledgeStopped(
      jobId: claimed.id, worker: worker, token: lease.token, now: Date().addingTimeInterval(1)
    )
    XCTAssertEqual(replay.stoppedAt, stopped.stoppedAt)
  }

  func testCancelledClaimRemainsUnarchivedUntilStopReceipt() async throws {
    let url = try storeURL()
    var limits = DistributedStoreLimits()
    limits.retainedTerminalJobs = 0
    let controller = try DistributedJobController(fileURL: url, limits: limits)
    let worker = try await controller.register(workerId: "worker", groups: [], capacity: 1)
    _ = try await controller.enqueue(id: "claimed", target: .init(), payload: [:])
    let claim = try await controller.claim(worker: worker, now: Date(), leaseDuration: 10)
    let token = try XCTUnwrap(claim?.lease?.token)
    try await controller.cancel(jobId: "claimed")
    let pending = try await controller.job(id: "claimed", now: Date())
    XCTAssertEqual(pending?.archived, nil)
    XCTAssertNil(pending?.stoppedAt)
    let stopped = try await controller.acknowledgeStopped(
      jobId: "claimed", worker: worker, token: token, now: Date()
    )
    let reopened = try DistributedJobController(fileURL: url, limits: limits)
    let archived = try await reopened.job(id: "claimed", now: Date())
    XCTAssertEqual(archived?.stoppedAt, stopped.stoppedAt)
    let replay = try await reopened.acknowledgeStopped(
      jobId: "claimed", worker: worker, token: token, now: Date().addingTimeInterval(1)
    )
    XCTAssertEqual(replay.stoppedAt, stopped.stoppedAt)
  }

  func testConcurrentNodeReattachmentUsesOneJobDespiteRegeneratedTimeouts() async throws {
    let url = try storeURL()
    let invocation = DistributedNodeInvocation.adapter(.init(node: .init(id: "node", model: "local"), promptText: "same work"))
    let jobs = try await withThrowingTaskGroup(of: DistributedJob.self) { group in
      for index in 0..<16 {
        group.addTask {
          let controller = try DistributedJobController(fileURL: url)
          return try await controller.enqueueNode(id: "same-execution", target: .init(group: "build"), request: .init(
            invocation: invocation, workspace: "project", timeoutSeconds: Double(index + 10)
          ))
        }
      }
      var results: [DistributedJob] = []
      for try await job in group { results.append(job) }
      return results
    }
    XCTAssertEqual(jobs.count, 16)
    XCTAssertTrue(jobs.allSatisfy { $0 == jobs.first })
    let controller = try DistributedJobController(fileURL: url)
    let persisted = try await controller.jobs(now: Date())
    XCTAssertEqual(persisted.count, 1)
    do {
      _ = try await controller.enqueueNode(id: "same-execution", target: .init(group: "build"), request: .init(
        invocation: invocation, workspace: "different", timeoutSeconds: 30
      ))
      XCTFail("Reattachment changed the work")
    } catch { XCTAssertEqual(error as? DistributedWorkerError, .conflictingJob) }
  }

  private func storeURL() throws -> URL {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/distributed-workers/tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    return root.appendingPathComponent("jobs.json")
  }

  func testExactTargetGroupAndCapacitySurviveRestart() async throws {
    let url = try storeURL()
    let controller = try DistributedJobController(fileURL: url)
    let now = Date(timeIntervalSince1970: 100)
    let mac = try await controller.register(workerId: "mac", groups: ["apple"], capacity: 1)
    let linux = try await controller.register(workerId: "linux", groups: ["linux"], capacity: 1)
    _ = try await controller.enqueue(id: "exact", target: .init(workerId: "linux", group: "linux"), payload: [:])
    _ = try await controller.enqueue(id: "group", target: .init(group: "apple"), payload: [:])
    _ = try await controller.enqueue(id: "unavailable", target: .init(workerId: "missing"), payload: [:])
    _ = try await controller.enqueue(id: "mismatch", target: .init(workerId: "mac", group: "linux"), payload: [:])
    let first = try await controller.claim(worker: mac, now: now, leaseDuration: 30)
    XCTAssertEqual(first?.id, "group")
    let second = try await controller.claim(worker: linux, now: now, leaseDuration: 30)
    XCTAssertEqual(second?.id, "exact")
    let restored = try DistributedJobController(fileURL: url)
    let atCapacity = try await restored.claim(worker: linux, now: now, leaseDuration: 30)
    XCTAssertNil(atCapacity)
    let jobs = try await restored.jobs(now: now)
    XCTAssertEqual(jobs.map(\.status), [.leased, .leased, .queued, .queued])
  }

  func testExpiredAndReplacedWorkersCannotCommitResults() async throws {
    let controller = try DistributedJobController(fileURL: storeURL())
    let now = Date(timeIntervalSince1970: 100)
    let worker = try await controller.register(workerId: "worker", groups: [], capacity: 2)
    for id in ["expires", "reconnect"] {
      _ = try await controller.enqueue(id: id, target: .init(), payload: [:])
    }
    let claimed = try await controller.claim(worker: worker, now: now, leaseDuration: 10)
    let lease = try XCTUnwrap(claimed?.lease)
    do {
      _ = try await controller.complete(
        jobId: "expires", worker: worker, token: lease.token, result: .init(outcome: .succeeded, payload: [:]),
        now: now.addingTimeInterval(10)
      )
      XCTFail("Expired lease accepted")
    } catch { XCTAssertEqual(error as? DistributedWorkerError, .staleLease) }
    do {
      _ = try await controller.acknowledgeStopped(
        jobId: "expires", worker: worker, token: lease.token, now: now.addingTimeInterval(10)
      )
      XCTFail("Lease expiry supplied worker-stop proof")
    } catch { XCTAssertEqual(error as? DistributedWorkerError, .staleLease) }
    _ = try await controller.claim(worker: worker, now: now.addingTimeInterval(10), leaseDuration: 30)
    let replacement = try await controller.register(workerId: "worker", groups: [], capacity: 2)
    do {
      _ = try await controller.claim(worker: worker, now: now, leaseDuration: 30)
      XCTFail("Replaced worker accepted")
    } catch { XCTAssertEqual(error as? DistributedWorkerError, .staleWorker) }
    let replay = try await controller.claim(worker: replacement, now: now, leaseDuration: 30)
    XCTAssertNil(replay, "Uncertain external effects must not be automatically replayed")
    let jobs = try await controller.jobs(now: now)
    XCTAssertEqual(jobs.map(\.status), [.lost, .lost])
  }

  func testCompletionIsIdempotentAndRejectsConflictsAndWrongWorker() async throws {
    let url = try storeURL()
    let controller = try DistributedJobController(fileURL: url)
    let now = Date(timeIntervalSince1970: 100)
    let worker = try await controller.register(workerId: "worker", groups: [], capacity: 1)
    let other = try await controller.register(workerId: "other", groups: [], capacity: 1)
    _ = try await controller.enqueue(id: "job", target: .init(), payload: [:])
    let claimed = try await controller.claim(worker: worker, now: now, leaseDuration: 30)
    let token = try XCTUnwrap(claimed?.lease?.token)
    let result = DistributedJobResult(outcome: .succeeded, payload: ["value": .string("remote")])
    do {
      _ = try await controller.complete(jobId: "job", worker: other, token: token, result: result, now: now)
      XCTFail("Another worker accepted")
    } catch { XCTAssertEqual(error as? DistributedWorkerError, .staleLease) }
    let completed = try await controller.complete(jobId: "job", worker: worker, token: token, result: result, now: now)
    let restored = try DistributedJobController(fileURL: url)
    let duplicate = try await restored.complete(jobId: "job", worker: worker, token: token, result: result, now: now.addingTimeInterval(100))
    XCTAssertEqual(completed, duplicate)
    do {
      _ = try await restored.complete(
        jobId: "job", worker: worker, token: token, result: .init(outcome: .failed, payload: [:]), now: now
      )
      XCTFail("Conflicting result accepted")
    } catch { XCTAssertEqual(error as? DistributedWorkerError, .conflictingResult) }
  }

  func testCancellationFencesCompletionAndReleasesCapacity() async throws {
    let controller = try DistributedJobController(fileURL: storeURL())
    let now = Date(timeIntervalSince1970: 100)
    let worker = try await controller.register(workerId: "worker", groups: [], capacity: 1)
    for id in ["cancel", "next"] { _ = try await controller.enqueue(id: id, target: .init(), payload: [:]) }
    let claimed = try await controller.claim(worker: worker, now: now, leaseDuration: 30)
    let token = try XCTUnwrap(claimed?.lease?.token)
    try await controller.cancel(jobId: "cancel")
    do {
      try await controller.renew(jobId: "cancel", worker: worker, token: token, now: now, leaseDuration: 30)
      XCTFail("Cancelled job renewed")
    } catch { XCTAssertEqual(error as? DistributedWorkerError, .staleLease) }
    let next = try await controller.claim(worker: worker, now: now, leaseDuration: 30)
    XCTAssertEqual(next?.id, "next")
  }

  func testConcurrentClaimsNeverDuplicateOrExceedCapacity() async throws {
    let controller = try DistributedJobController(fileURL: storeURL())
    let now = Date(timeIntervalSince1970: 100)
    let worker = try await controller.register(workerId: "worker", groups: [], capacity: 3)
    for index in 0..<10 { _ = try await controller.enqueue(id: "job-\(index)", target: .init(), payload: [:]) }
    let claimed = try await withThrowingTaskGroup(of: String?.self) { group in
      for _ in 0..<10 {
        group.addTask { try await controller.claim(worker: worker, now: now, leaseDuration: 30)?.id }
      }
      var ids: [String] = []
      for try await id in group { if let id { ids.append(id) } }
      return ids
    }
    XCTAssertEqual(claimed.count, 3)
    XCTAssertEqual(Set(claimed).count, 3)
  }

  func testRenewalAndEnqueueConflict() async throws {
    let controller = try DistributedJobController(fileURL: storeURL())
    let now = Date(timeIntervalSince1970: 100)
    let worker = try await controller.register(workerId: "worker", groups: [], capacity: 1)
    let original = try await controller.enqueue(id: "job", target: .init(), payload: [:])
    let duplicate = try await controller.enqueue(id: "job", target: .init(), payload: [:])
    XCTAssertEqual(original, duplicate)
    do {
      _ = try await controller.enqueue(id: "job", target: .init(workerId: "different"), payload: [:])
      XCTFail("Conflicting enqueue accepted")
    } catch { XCTAssertEqual(error as? DistributedWorkerError, .conflictingJob) }
    let claimed = try await controller.claim(worker: worker, now: now, leaseDuration: 10)
    let token = try XCTUnwrap(claimed?.lease?.token)
    try await controller.renew(jobId: "job", worker: worker, token: token, now: now.addingTimeInterval(9), leaseDuration: 20)
    let jobs = try await controller.jobs(now: now.addingTimeInterval(11))
    XCTAssertEqual(jobs.first?.status, .leased)
    XCTAssertEqual(jobs.first?.lease?.expiresAt, now.addingTimeInterval(29))
  }

  func testFailedPersistenceDoesNotAcceptMutation() async throws {
    let url = try storeURL()
    let controller = try DistributedJobController(fileURL: url)
    // A directory is not a readable/writable snapshot destination.
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    do {
      _ = try await controller.enqueue(id: "job", target: .init(), payload: [:])
      XCTFail("Unpersisted enqueue acknowledged")
    } catch { XCTAssertEqual(error as? DistributedWorkerError, .storeUnavailable) }
    try FileManager.default.removeItem(at: url)
    let jobs = try await controller.jobs(now: Date(timeIntervalSince1970: 100))
    XCTAssertTrue(jobs.isEmpty)
  }

  func testIndependentStoreClientsDoNotLoseUpdatesOrDuplicateClaims() async throws {
    let url = try storeURL()
    let first = try DistributedJobController(fileURL: url)
    let second = try DistributedJobController(fileURL: url)
    let worker = try await first.register(workerId: "shared", groups: [], capacity: 10)
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<10 {
        group.addTask {
          let controller = index.isMultiple(of: 2) ? first : second
          _ = try await controller.enqueue(id: "job-\(index)", target: .init(), payload: [:])
        }
      }
      try await group.waitForAll()
    }
    let claimed = try await withThrowingTaskGroup(of: String?.self) { group in
      for index in 0..<10 {
        group.addTask {
          try await (index.isMultiple(of: 2) ? first : second).claim(worker: worker, now: Date(), leaseDuration: 30)?.id
        }
      }
      var ids: [String] = []
      for try await id in group { if let id { ids.append(id) } }
      return ids
    }
    XCTAssertEqual(Set(claimed).count, 10)
    let jobs = try await second.jobs(now: Date())
    XCTAssertEqual(jobs.count, 10)
    XCTAssertTrue(jobs.allSatisfy { $0.status == .leased })
  }

  func testSnapshotsArePrivateAndUnchangedReadsDoNotRewrite() async throws {
    let url = try storeURL()
    let controller = try DistributedJobController(fileURL: url)
    _ = try await controller.enqueue(id: "private", target: .init(), payload: [:])
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    let prior = Date(timeIntervalSince1970: 100)
    try FileManager.default.setAttributes([.modificationDate: prior], ofItemAtPath: url.path)
    _ = try await controller.jobs(now: Date())
    let after = try FileManager.default.attributesOfItem(atPath: url.path)
    XCTAssertEqual(after[.modificationDate] as? Date, prior)
    let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
    XCTAssertFalse(files.contains { $0.hasPrefix(".distributed-snapshot-") })
  }

  func testTaskWorkerInspectionLeavesExpiredLeaseSnapshotUnchanged() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent(
      "tmp/work-runtime-p1-selected-host-delivery/tests/T5-controller/\(UUID().uuidString)", isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("jobs.json")
    let controller = try DistributedJobController(fileURL: url)
    let now = Date(timeIntervalSince1970: 100)
    let worker = try await controller.register(workerId: "remote", groups: [], capacity: 1, now: now)
    _ = try await controller.enqueue(id: "job", target: .init(workerId: "remote"), payload: [:])
    _ = try await controller.claim(worker: worker, now: now, leaseDuration: 10)
    let before = try Data(contentsOf: url)
    let statuses = try await controller.inspectWorkers(now: now.addingTimeInterval(11))
    XCTAssertEqual(statuses.first?.workerId, "remote")
    XCTAssertEqual(statuses.first?.activeJobIds, [])
    XCTAssertEqual(statuses.first?.online, true)
    XCTAssertEqual(try Data(contentsOf: url), before)
  }

  func testWorkerStatusTracksIdleAndBusyHeartbeatsWithoutCredentials() async throws {
    let controller = try DistributedJobController(fileURL: storeURL())
    let now = Date(timeIntervalSince1970: 100)
    let worker = try await controller.register(workerId: "machine", groups: ["build"], capacity: 2, now: now)
    var status = try await controller.workers(now: now)
    XCTAssertEqual(status.first?.online, true)
    XCTAssertEqual(status.first?.activeJobIds, [])
    _ = try await controller.enqueue(id: "job", target: .init(), payload: [:])
    let claim = try await controller.claim(worker: worker, now: now.addingTimeInterval(20), leaseDuration: 30)
    status = try await controller.workers(now: now.addingTimeInterval(35))
    XCTAssertEqual(status.first?.online, true)
    XCTAssertEqual(status.first?.activeJobIds, ["job"])
    let token = try XCTUnwrap(claim?.lease?.token)
    try await controller.renew(jobId: "job", worker: worker, token: token, now: now.addingTimeInterval(40), leaseDuration: 30)
    status = try await controller.workers(now: now.addingTimeInterval(71))
    XCTAssertEqual(status.first?.online, false)
    XCTAssertEqual(status.first?.activeJobIds, [])
    let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(status), encoding: .utf8))
    XCTAssertFalse(encoded.contains(token))
    XCTAssertFalse(encoded.contains(worker.incarnation))
  }

  func testRemoteEventHistoryIsBoundedAndFenced() async throws {
    let controller = try DistributedJobController(fileURL: storeURL())
    let now = Date()
    let worker = try await controller.register(workerId: "events", groups: [], capacity: 1)
    _ = try await controller.enqueue(id: "job", target: .init(), payload: [:])
    let claimed = try await controller.claim(worker: worker, now: now, leaseDuration: 30)
    let token = try XCTUnwrap(claimed?.lease?.token)
    for start in stride(from: 1, through: 129, by: 16) {
      let events = (start..<min(start + 16, 131)).map {
        DistributedJobEvent(sequence: $0, event: .init(provider: "test", eventType: "progress", contentSnapshot: "\($0)"))
      }
      try await controller.appendEvents(jobId: "job", worker: worker, token: token, events: events, now: now)
    }
    let job = try await controller.jobs(now: now).first
    XCTAssertEqual(job?.eventCount, 130)
    XCTAssertEqual(job?.events?.count, 128)
    XCTAssertEqual(job?.events?.first?.sequence, 3)
    try await controller.cancel(jobId: "job")
    do {
      try await controller.appendEvents(
        jobId: "job", worker: worker, token: token,
        events: [.init(sequence: 131, event: .init(provider: "test", eventType: "late"))], now: now
      )
      XCTFail("Cancelled execution accepted remote events")
    } catch { XCTAssertEqual(error as? DistributedWorkerError, .staleLease) }
  }
}
