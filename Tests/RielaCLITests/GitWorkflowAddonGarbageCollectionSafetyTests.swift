import Foundation
import XCTest
@testable import RielaCLI
@testable import RielaCore

final class GitAddonGarbageCollectionSafetyTests: XCTestCase {
  func testTerminalMaintenanceRejectsMatchingExecutionFromAnotherRepository() async throws {
    let repository = try GitTestRepository()
    let workflowExecutionID = "shared-workflow-exec"
    let stepExecutionID = "shared-step-exec"
    try repository.write("unaccepted content", to: "tracked.txt")
    await XCTAssertThrowsErrorAsync(
      try await repository.makeResolver(
        failureInjector: ThrowOnceGitFinalizationFailureInjector(phase: .outputPublication)
      ).execute(
        makeGitCommitInput(
          message: "test: repository-bound terminal maintenance",
          files: ["tracked.txt"],
          workflowExecutionId: workflowExecutionID,
          stepExecutionId: stepExecutionID
        ),
        context: AdapterExecutionContext()
      )
    ) { _ in }

    let foreignRepository = try GitTestRepository()
    let foreignResolver = BuiltinWorkflowAddonResolver(
      environment: ProcessInfo.processInfo.environment,
      workingDirectory: foreignRepository.root,
      gitFinalizationStore: GitFinalizationStore(rootDirectory: repository.finalizationRoot)
    )
    try await foreignResolver.recordTerminalFinalization(
      workflowExecutionId: workflowExecutionID,
      stepExecutionIds: [stepExecutionID]
    )

    XCTAssertEqual(try repository.finalizationArtifacts(in: "terminal"), [])
    XCTAssertEqual(try repository.finalizationArtifacts(in: "journals").count, 1)
  }

  func testTerminalMaintenanceCollectsOnlyTerminalWorkflowArtifacts() async throws {
    let repository = try GitTestRepository()
    let activeExecutionID = "active-unaccepted-exec"
    try repository.write("active committed content", to: "tracked.txt")
    await XCTAssertThrowsErrorAsync(
      try await repository.makeResolver(
        failureInjector: ThrowOnceGitFinalizationFailureInjector(phase: .outputPublication)
      ).execute(
        makeGitCommitInput(
          message: "test: active unaccepted transaction",
          files: ["tracked.txt"],
          workflowExecutionId: "active-unaccepted-workflow",
          stepExecutionId: activeExecutionID
        ),
        context: AdapterExecutionContext()
      )
    ) { _ in }

    try repository.write("terminal committed content", to: "tracked.txt")
    let terminalResolver = CompositeWorkflowAddonResolver(
      primary: repository.makeResolver(
        failureInjector: ThrowOnceGitFinalizationFailureInjector(phase: .outputPublication)
      ),
      fallback: GarbageCollectionRejectingAddonResolver()
    )
    await XCTAssertThrowsErrorAsync(
      try await DeterministicWorkflowRunner(addonResolver: terminalResolver).run(
        DeterministicWorkflowRunRequest(
          workflow: terminalCommitWorkflow(),
          variables: terminalCommitVariables(
            message: "test: terminal transaction",
            files: ["tracked.txt"]
          )
        )
      )
    ) { _ in }
    XCTAssertEqual(try repository.finalizationArtifacts(in: "terminal").count, 1)

    let oldDate = Date().addingTimeInterval(-8 * 24 * 60 * 60)
    for directory in ["journals", "prepared", "links"] {
      for artifact in try repository.finalizationArtifacts(in: directory) {
        try FileManager.default.setAttributes(
          [.modificationDate: oldDate],
          ofItemAtPath: repository.finalizationRoot
            .appendingPathComponent(directory)
            .appendingPathComponent(artifact).path
        )
      }
    }

    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(
        makeGitPushInput(repository: repository),
        context: AdapterExecutionContext()
      )
    ) { _ in }

    let store = GitFinalizationStore(rootDirectory: repository.finalizationRoot)
    XCTAssertEqual(
      try store.loadJournal(predecessorStepExecutionId: activeExecutionID).workflowExecutionId,
      "active-unaccepted-workflow"
    )
    XCTAssertEqual(try repository.finalizationArtifacts(in: "journals").count, 1)
    XCTAssertEqual(try repository.finalizationArtifacts(in: "prepared").count, 1)
    XCTAssertEqual(try repository.finalizationArtifacts(in: "links").count, 1)
    XCTAssertEqual(try repository.finalizationArtifacts(in: "terminal"), [])
  }

  func testTerminalMaintenanceHandlesMoreThanDirectoryEntryLimitExecutions() async throws {
    let repository = try GitTestRepository()
    let workflowExecutionID = "large-terminal-workflow"
    let stepExecutionID = "large-terminal-git-execution"
    try repository.write("terminal content", to: "tracked.txt")
    await XCTAssertThrowsErrorAsync(
      try await repository.makeResolver(
        failureInjector: ThrowOnceGitFinalizationFailureInjector(phase: .outputPublication)
      ).execute(
        makeGitCommitInput(
          message: "test: large terminal execution history",
          files: ["tracked.txt"],
          workflowExecutionId: workflowExecutionID,
          stepExecutionId: stepExecutionID
        ),
        context: AdapterExecutionContext()
      )
    ) { _ in }
    let oldDate = Date().addingTimeInterval(-8 * 24 * 60 * 60)
    for directory in ["journals", "prepared", "links"] {
      for artifact in try repository.finalizationArtifacts(in: directory) {
        try FileManager.default.setAttributes(
          [.modificationDate: oldDate],
          ofItemAtPath: repository.finalizationRoot
            .appendingPathComponent(directory)
            .appendingPathComponent(artifact).path
        )
      }
    }
    let unrelatedExecutionIDs = (0..<4_096).map { "unrelated-execution-\($0)" }

    try await repository.resolver.recordTerminalFinalization(
      workflowExecutionId: workflowExecutionID,
      stepExecutionIds: unrelatedExecutionIDs + [stepExecutionID]
    )

    XCTAssertEqual(try repository.finalizationArtifacts(in: "journals"), [])
    XCTAssertEqual(try repository.finalizationArtifacts(in: "prepared"), [])
    XCTAssertEqual(try repository.finalizationArtifacts(in: "links"), [])
    XCTAssertEqual(try repository.finalizationArtifacts(in: "terminal"), [])
  }

  func testAutomaticPreparationRetainsOldUnacceptedRetryJournal() async throws {
    let repository = try GitTestRepository()
    let firstExecutionID = "old-unaccepted-exec-1"
    let message = "test: retain old unaccepted retry journal"
    try repository.write("first committed content", to: "tracked.txt")

    await XCTAssertThrowsErrorAsync(
      try await repository.makeResolver(
        failureInjector: ThrowOnceGitFinalizationFailureInjector(phase: .outputPublication)
      ).execute(
        makeGitCommitInput(
          message: message,
          files: ["tracked.txt"],
          stepExecutionId: firstExecutionID
        ),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.isRetryable, true)
    }
    let committedRevision = try repository.git(["rev-parse", "HEAD"]).trimmed
    let oldDate = Date().addingTimeInterval(-8 * 24 * 60 * 60)
    for directory in ["journals", "prepared", "links"] {
      for artifact in try repository.finalizationArtifacts(in: directory) {
        try FileManager.default.setAttributes(
          [.modificationDate: oldDate],
          ofItemAtPath: repository.finalizationRoot
            .appendingPathComponent(directory)
            .appendingPathComponent(artifact).path
        )
      }
    }
    try repository.write("later uncommitted content", to: "tracked.txt")

    let recovered = try await repository.resolver.execute(
      makeGitCommitInput(
        message: message,
        files: ["tracked.txt"],
        stepExecutionId: "old-unaccepted-exec-2",
        attempt: 2,
        predecessorStepExecutionId: firstExecutionID
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertGitCommitEvidence(
      recovered.payload,
      status: "already-committed",
      revision: committedRevision,
      message: message,
      files: ["tracked.txt"]
    )
    XCTAssertEqual(try repository.git(["rev-parse", "HEAD"]).trimmed, committedRevision)
    XCTAssertEqual(try repository.git(["rev-list", "--count", "HEAD"]).trimmed, "2")
    XCTAssertEqual(try repository.git(["diff", "--", "tracked.txt"]).isEmpty, false)
  }

  func testAttemptIndexRejectsPostPrepareTemporaryDirectorySymlinkSwap() throws {
    try assertManagedDirectorySymlinkSwapRejected(directoryName: "tmp") { store in
      _ = try store.makeAttemptIndex(copying: Data("index".utf8))
    }
  }

  func testAttemptIndexRejectsPostPrepareRootDirectorySymlinkSwap() throws {
    let fixture = try GitFinalizationStoreFixture()
    let parent = fixture.root.deletingLastPathComponent()
    let displaced = parent.appendingPathComponent("displaced-\(UUID().uuidString)", isDirectory: true)
    let target = parent.appendingPathComponent("target-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    try FileManager.default.moveItem(at: fixture.root, to: displaced)
    try FileManager.default.createSymbolicLink(at: fixture.root, withDestinationURL: target)
    defer {
      try? FileManager.default.removeItem(at: fixture.root)
      try? FileManager.default.removeItem(at: displaced)
      try? FileManager.default.removeItem(at: target)
    }

    XCTAssertThrowsError(try fixture.store.makeAttemptIndex(copying: Data("index".utf8))) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
    }
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
  }

  func testJournalRejectsPostPrepareManagedDirectorySymlinkSwap() throws {
    try assertManagedDirectorySymlinkSwapRejected(directoryName: "journals") { store in
      try store.writeCreateOnly(
        Data("journal".utf8),
        to: store.journalsDirectory.appendingPathComponent("journal.json"),
        maxBytes: 512 * 1_024
      )
    }
  }

  func testAcceptedMarkerRejectsPostPrepareManagedDirectorySymlinkSwap() throws {
    try assertManagedDirectorySymlinkSwapRejected(directoryName: "accepted") { store in
      try store.acknowledge(WorkflowAddonFinalizationToken(
        value: "git-finalization-v1:\(String(repeating: "a", count: 64)):accepted-token"
      ))
    }
  }

  func testTerminalMarkerRejectsPostPrepareManagedDirectorySymlinkSwap() throws {
    let fixture = try GitFinalizationStoreFixture()
    let journal = try fixture.writeJournal(
      key: String(repeating: "b", count: 64),
      executionID: "terminal-symlink-execution",
      workflowExecutionID: "terminal-symlink-workflow"
    )
    try replaceManagedDirectoryWithSymlink(
      fixture: fixture,
      directoryName: "terminal"
    ) { target in
      XCTAssertThrowsError(try fixture.store.recordTerminalWorkflowExecution(
        journal.workflowExecutionId,
        stepExecutionIds: [journal.stepExecutionId],
        repository: journal.repository
      )) { error in
        XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      }
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
    }
  }

  func testTransportRepositoryRejectsPostPrepareManagedDirectorySymlinkSwap() throws {
    try assertManagedDirectorySymlinkSwapRejected(directoryName: "transport") { store in
      _ = try store.makeTransportRepositoryDirectory()
    }
  }

  func testTransportCleanupPreservesConcurrentPathReplacement() throws {
    let fixture = try GitFinalizationStoreFixture()
    let owned = try fixture.store.makeTransportRepositoryDirectory()
    let displaced = fixture.root.appendingPathComponent("displaced-transport", isDirectory: true)
    try FileManager.default.moveItem(at: owned.url, to: displaced)
    try FileManager.default.createDirectory(at: owned.url, withIntermediateDirectories: false)
    let replacement = owned.url.appendingPathComponent("replacement.txt")
    try Data("unrelated".utf8).write(to: replacement)

    XCTAssertFalse(try fixture.store.removeOwnedTransportRepository(owned))
    XCTAssertEqual(try Data(contentsOf: replacement), Data("unrelated".utf8))
    XCTAssertTrue(FileManager.default.fileExists(atPath: displaced.path))
  }

  func testGarbageCollectionRemovesCrashOrphanedTransportRepository() throws {
    let fixture = try GitFinalizationStoreFixture()
    let owned = try fixture.store.makeTransportRepositoryDirectory()
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1)],
      ofItemAtPath: owned.url.path
    )

    try fixture.store.garbageCollectFailedArtifacts(olderThan: Date(), limit: 1)

    XCTAssertFalse(FileManager.default.fileExists(atPath: owned.url.path))
  }

  func testGarbageCollectionPreservesReplacementBetweenEligibilityAndCleanupOpen() throws {
    let fixture = try GitFinalizationStoreFixture()
    let temporaryDirectory = fixture.root.appendingPathComponent("tmp", isDirectory: true)
    let candidate = temporaryDirectory.appendingPathComponent("old-candidate")
    let displaced = fixture.root.appendingPathComponent("displaced-candidate")
    let replacement = fixture.root.appendingPathComponent("replacement")
    let replacementData = Data("unrelated".utf8)
    XCTAssertTrue(FileManager.default.createFile(atPath: candidate.path, contents: Data("old".utf8)))
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1)],
      ofItemAtPath: candidate.path
    )
    try replacementData.write(to: replacement)

    try fixture.store.garbageCollectFailedArtifacts(
      olderThan: Date(),
      limit: 1,
      beforeRemoval: { url in
        guard url == candidate else { return }
        try FileManager.default.moveItem(at: candidate, to: displaced)
        try FileManager.default.moveItem(at: replacement, to: candidate)
      }
    )

    XCTAssertEqual(try Data(contentsOf: candidate), replacementData)
    XCTAssertEqual(try Data(contentsOf: displaced), Data("old".utf8))
  }

  func testGarbageCollectionRestoresReplacementAfterPathValidation() throws {
    let fixture = try GitFinalizationStoreFixture()
    let temporaryDirectory = fixture.root.appendingPathComponent("tmp", isDirectory: true)
    let candidate = temporaryDirectory.appendingPathComponent("old-candidate")
    let displaced = fixture.root.appendingPathComponent("displaced-candidate")
    let replacement = fixture.root.appendingPathComponent("replacement")
    let replacementData = Data("unrelated".utf8)
    XCTAssertTrue(FileManager.default.createFile(atPath: candidate.path, contents: Data("old".utf8)))
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1)],
      ofItemAtPath: candidate.path
    )
    try replacementData.write(to: replacement)

    try fixture.store.garbageCollectFailedArtifacts(
      olderThan: Date(),
      limit: 1,
      afterRemovalValidation: { url in
        guard url == candidate else { return }
        try FileManager.default.moveItem(at: candidate, to: displaced)
        try FileManager.default.moveItem(at: replacement, to: candidate)
      }
    )

    XCTAssertEqual(try Data(contentsOf: candidate), replacementData)
    XCTAssertEqual(try Data(contentsOf: displaced), Data("old".utf8))
  }

  func testGarbageCollectionRemovesExactOldTemporaryEntry() throws {
    let fixture = try GitFinalizationStoreFixture()
    let candidate = fixture.root.appendingPathComponent("tmp/old-candidate")
    XCTAssertTrue(FileManager.default.createFile(atPath: candidate.path, contents: Data("old".utf8)))
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1)],
      ofItemAtPath: candidate.path
    )

    try fixture.store.garbageCollectFailedArtifacts(olderThan: Date(), limit: 1)

    XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))
  }

  func testGarbageCollectionRemovesOldAcceptedMarkerWithoutRetainedJournal() throws {
    let fixture = try GitFinalizationStoreFixture()
    try fixture.store.acknowledge(WorkflowAddonFinalizationToken(
      value: "git-finalization-v1:\(String(repeating: "c", count: 64)):collected-token"
    ))
    try setAcceptedMarkerDates(fixture: fixture, date: Date(timeIntervalSince1970: 1))

    try fixture.store.garbageCollectFailedArtifacts(olderThan: Date(), limit: 1)

    XCTAssertEqual(try acceptedMarkerNames(fixture: fixture), [])
  }

  func testGarbageCollectionRetainsRecentAcceptedMarker() throws {
    let fixture = try GitFinalizationStoreFixture()
    try fixture.store.acknowledge(WorkflowAddonFinalizationToken(
      value: "git-finalization-v1:\(String(repeating: "d", count: 64)):recent-token"
    ))

    try fixture.store.garbageCollectFailedArtifacts(limit: 1)

    XCTAssertEqual(try acceptedMarkerNames(fixture: fixture).count, 1)
  }

  func testGarbageCollectionRetainsOldAcceptedMarkerWhoseJournalRemains() throws {
    let fixture = try GitFinalizationStoreFixture()
    let journalKey = String(repeating: "e", count: 64)
    try fixture.store.acknowledge(WorkflowAddonFinalizationToken(
      value: "git-finalization-v1:\(journalKey):\(journalKey)"
    ))
    _ = try fixture.writeJournal(key: journalKey, executionID: "retained-journal-execution")
    try setAcceptedMarkerDates(fixture: fixture, date: Date(timeIntervalSince1970: 1))

    try fixture.store.garbageCollectFailedArtifacts(olderThan: Date(), limit: 1)

    XCTAssertEqual(try acceptedMarkerNames(fixture: fixture).count, 1)
  }

  func testGarbageCollectionRetainsOldAcceptedMarkerWithMismatchedName() throws {
    let fixture = try GitFinalizationStoreFixture()
    let acceptedDirectory = fixture.root.appendingPathComponent("accepted", isDirectory: true)
    let markerURL = acceptedDirectory.appendingPathComponent(String(repeating: "f", count: 64) + ".json")
    let markerData = Data(
      "{\"journalKey\":\"\(String(repeating: "0", count: 64))\",\"operationToken\":\"mismatched\"}".utf8
    )
    XCTAssertTrue(FileManager.default.createFile(atPath: markerURL.path, contents: markerData))
    try setAcceptedMarkerDates(fixture: fixture, date: Date(timeIntervalSince1970: 1))

    try fixture.store.garbageCollectFailedArtifacts(olderThan: Date(), limit: 1)

    XCTAssertEqual(try acceptedMarkerNames(fixture: fixture).count, 1)
  }

  private func acceptedMarkerNames(fixture: GitFinalizationStoreFixture) throws -> [String] {
    try FileManager.default.contentsOfDirectory(
      atPath: fixture.root.appendingPathComponent("accepted", isDirectory: true).path
    ).filter { !$0.hasPrefix(".") }
  }

  private func setAcceptedMarkerDates(fixture: GitFinalizationStoreFixture, date: Date) throws {
    let acceptedDirectory = fixture.root.appendingPathComponent("accepted", isDirectory: true)
    for name in try acceptedMarkerNames(fixture: fixture) {
      try FileManager.default.setAttributes(
        [.modificationDate: date],
        ofItemAtPath: acceptedDirectory.appendingPathComponent(name).path
      )
    }
  }

  func testGarbageCollectionRejectsDirectoryEntryLimitExhaustion() throws {
    let fixture = try GitFinalizationStoreFixture()
    let temporaryDirectory = fixture.root.appendingPathComponent("tmp", isDirectory: true)
    XCTAssertTrue(FileManager.default.createFile(
      atPath: temporaryDirectory.appendingPathComponent("first").path,
      contents: Data()
    ))
    XCTAssertTrue(FileManager.default.createFile(
      atPath: temporaryDirectory.appendingPathComponent("second").path,
      contents: Data()
    ))

    XCTAssertThrowsError(try fixture.store.garbageCollectFailedArtifacts(
      olderThan: Date(),
      limit: 1,
      entryLimit: 1
    )) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("entry limit") == true)
    }
  }

  func testGarbageCollectionHonorsExpiredWorkflowDeadline() throws {
    let fixture = try GitFinalizationStoreFixture()

    XCTAssertThrowsError(try GitCommandRuntimeContext.$deadline.withValue(.distantPast) {
      try fixture.store.garbageCollectFailedArtifacts()
    }) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .timeout)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("workflow deadline") == true)
    }
  }

  private func assertManagedDirectorySymlinkSwapRejected(
    directoryName: String,
    operation: (GitFinalizationStore) throws -> Void
  ) throws {
    let fixture = try GitFinalizationStoreFixture()
    try replaceManagedDirectoryWithSymlink(
      fixture: fixture,
      directoryName: directoryName
    ) { target in
      XCTAssertThrowsError(try operation(fixture.store)) { error in
        XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      }
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
    }
  }

  private func replaceManagedDirectoryWithSymlink(
    fixture: GitFinalizationStoreFixture,
    directoryName: String,
    assertions: (URL) throws -> Void
  ) throws {
    let managed = fixture.root.appendingPathComponent(directoryName, isDirectory: true)
    let displaced = fixture.root.appendingPathComponent(".displaced-\(directoryName)", isDirectory: true)
    let target = fixture.root.appendingPathComponent(".target-\(directoryName)", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    try FileManager.default.moveItem(at: managed, to: displaced)
    try FileManager.default.createSymbolicLink(at: managed, withDestinationURL: target)
    try assertions(target)
  }

  private func terminalCommitWorkflow() -> WorkflowDefinition {
    let addon = WorkflowNodeAddonRef(
      name: BuiltinGitAddon.commit.rawValue,
      version: "1",
      config: [
        "allowCommit": .bool(true),
        "commitMessageTemplate": .string("{{message}}"),
        "committedFilesTemplate": .string("{{files}}")
      ]
    )
    return WorkflowDefinition(
      workflowId: "git-terminal-maintenance-test",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "commit",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "commit", addon: addon)],
      steps: [WorkflowStepRef(id: "commit", nodeId: "commit")],
      nodes: [WorkflowNodeRef(id: "commit", addon: addon)]
    )
  }

  private func terminalCommitVariables(message: String, files: [String]) -> JSONObject {
    [
      "message": .string(message),
      "files": .array(files.map(JSONValue.string))
    ]
  }
}

private struct GarbageCollectionRejectingAddonResolver: WorkflowAddonResolving {
  func execute(
    _: WorkflowAddonExecutionInput,
    context _: AdapterExecutionContext
  ) async throws -> AdapterExecutionOutput {
    throw AdapterExecutionError(.providerError, "unexpected fallback add-on execution")
  }
}
