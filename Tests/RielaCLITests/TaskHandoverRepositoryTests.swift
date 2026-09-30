import Foundation
import RielaCore
import RielaWork
import XCTest
@testable import RielaCLI

private actor CheckpointRecordingWorkspace: WorkspaceHandoverRuntime {
  private(set) var active = 0
  private(set) var maximumActive = 0
  private(set) var trailers: [String] = []

  func ensureBranch(
    root: String, attempt: AttemptID, task: TaskID, generation: Int, base: String?,
    isolation: RepositoryIsolation, template: String
  ) async throws -> IsolationRef { throw WorkStoreError("unused") }

  func checkpoint(_ isolation: IsolationRef, message: String, trailer: String, paths: [String]?) async throws -> String? {
    active += 1
    maximumActive = max(maximumActive, active)
    trailers.append(trailer)
    try await Task.sleep(for: .milliseconds(20))
    active -= 1
    return "commit"
  }

  func publish(_ isolation: IsolationRef, remote: String, allowCreate: Bool, branchAllowlist: String) async throws -> PublishedBranch {
    throw WorkStoreError("unused")
  }

  func materialize(_ deliverable: RepositoryDeliverable, into root: String, worktree: Bool, attempt: AttemptID) async throws -> IsolationRef {
    throw WorkStoreError("unused")
  }

  func dirtyPaths(_ isolation: IsolationRef) async throws -> [String] { [] }
}

final class TaskHandoverRepositoryTests: XCTestCase {
  func testTimerCheckpointsAreSerializedAndUseUniqueTrailers() async throws {
    let workspace = CheckpointRecordingWorkspace()
    let coordinator = TaskHandoverCheckpointCoordinator()
    let isolation = IsolationRef(path: "/tmp/repository", branch: "task", baseRevision: "base")
    let attemptId = AttemptID("attempt-timer")
    async let first: Void = coordinator.checkpoint(
      workspace: workspace, isolation: isolation, attemptId: attemptId,
      message: "timer", trailerSuffix: "timer", paths: nil
    )
    async let second: Void = coordinator.checkpoint(
      workspace: workspace, isolation: isolation, attemptId: attemptId,
      message: "timer", trailerSuffix: "timer", paths: nil
    )
    try await first
    try await second

    let trailers = await workspace.trailers
    XCTAssertEqual(Set(trailers), Set([
      "Riela-Checkpoint: attempt-timer/timer-1", "Riela-Checkpoint: attempt-timer/timer-2"
    ]))
    let maximumActive = await workspace.maximumActive
    XCTAssertEqual(maximumActive, 1)
  }
}
