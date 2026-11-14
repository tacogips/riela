import Foundation
import XCTest
@testable import RielaCLI
@testable import RielaCore

final class GitWorkflowAddonRecoveryTests: XCTestCase {
  func testCommitCreatesRecoveryReflogWhenRepositoryLoggingIsDisabled() async throws {
    let repository = try GitTestRepository()
    _ = try repository.git(["config", "core.logAllRefUpdates", "false"])
    let reflogPath = try repository.git(["rev-parse", "--git-path", "logs/refs/heads/main"]).trimmed
    let reflogURL = URL(fileURLWithPath: reflogPath, relativeTo: repository.root).standardizedFileURL
    if FileManager.default.fileExists(atPath: reflogURL.path) {
      try FileManager.default.removeItem(at: reflogURL)
    }
    try repository.write("reflog recovery", to: "tracked.txt")
    let firstExecutionId = "create-reflog-exec-1"

    await XCTAssertThrowsErrorAsync(
      try await repository.makeResolver(
        failureInjector: ThrowOnceGitFinalizationFailureInjector(phase: .refUpdate)
      ).execute(
        makeGitCommitInput(
          message: "test: create recovery reflog",
          files: ["tracked.txt"],
          stepExecutionId: firstExecutionId
        ),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.isRetryable, true)
    }
    let reflog = try repository.git(["reflog", "show", "--format=%gs", "-n", "1", "refs/heads/main"]).trimmed
    XCTAssertTrue(reflog.hasPrefix("riela-finalization:"))

    let recovered = try await repository.resolver.execute(
      makeGitCommitInput(
        message: "test: create recovery reflog",
        files: ["tracked.txt"],
        stepExecutionId: "create-reflog-exec-2",
        attempt: 2,
        predecessorStepExecutionId: firstExecutionId
      ),
      context: AdapterExecutionContext()
    )
    XCTAssertGitCommitEvidence(
      recovered.payload,
      status: "already-committed",
      revision: try repository.git(["rev-parse", "HEAD"]).trimmed,
      message: "test: create recovery reflog",
      files: ["tracked.txt"]
    )
  }

  func testRetryRejectsMissingOrCorruptJournalWithoutChangingGitState() async throws {
    for corruptJournal in [false, true] {
      let repository = try GitTestRepository()
      try repository.write("journal-state", to: "tracked.txt")
      let headBefore = try repository.git(["rev-parse", "HEAD"]).trimmed
      let indexBefore = try repository.indexData()
      let firstExecutionId = corruptJournal ? "corrupt-journal-exec-1" : "missing-journal-exec-1"

      await XCTAssertThrowsErrorAsync(
        try await repository.makeResolver(
          failureInjector: ThrowOnceGitFinalizationFailureInjector(phase: .journal)
        ).execute(
          makeGitCommitInput(
            message: "test: journal state",
            files: ["tracked.txt"],
            stepExecutionId: firstExecutionId
          ),
          context: AdapterExecutionContext()
        )
      ) { _ in }
      let journalName = try XCTUnwrap(repository.finalizationArtifacts(in: "journals").first)
      let journalURL = repository.finalizationRoot.appendingPathComponent("journals/\(journalName)")
      if corruptJournal {
        let malformedJournal = Data("not-json".utf8)
        try malformedJournal.write(to: journalURL)
        let linkName = try XCTUnwrap(repository.finalizationArtifacts(in: "links").first)
        let linkURL = repository.finalizationRoot.appendingPathComponent("links/\(linkName)")
        var link = try XCTUnwrap(
          JSONSerialization.jsonObject(with: Data(contentsOf: linkURL)) as? [String: Any]
        )
        link["journalDigest"] = sha256(malformedJournal)
        try JSONSerialization.data(withJSONObject: link, options: [.sortedKeys]).write(to: linkURL)
      } else {
        try FileManager.default.removeItem(at: journalURL)
      }

      await XCTAssertThrowsErrorAsync(
        try await repository.resolver.execute(
          makeGitCommitInput(
            message: "test: journal state",
            files: ["tracked.txt"],
            stepExecutionId: corruptJournal ? "corrupt-journal-exec-2" : "missing-journal-exec-2",
            attempt: 2,
            predecessorStepExecutionId: firstExecutionId
          ),
          context: AdapterExecutionContext()
        )
      ) { error in
        let adapterError = error as? AdapterExecutionError
        XCTAssertEqual(adapterError?.code, .policyBlocked)
        XCTAssertEqual(adapterError?.isRetryable, false)
        XCTAssertLessThan(adapterError?.message.utf8.count ?? .max, 128)
        XCTAssertFalse(adapterError?.message.contains(repository.finalizationRoot.path) == true)
        XCTAssertFalse(adapterError?.message.contains("NSFilePath") == true)
        XCTAssertFalse(adapterError?.message.contains("NSURL") == true)
      }
      XCTAssertEqual(try repository.git(["rev-parse", "HEAD"]).trimmed, headBefore)
      XCTAssertEqual(try repository.indexData(), indexBefore)
    }
  }

  func testRetryRejectsByteIdenticalIndexReplacementAcrossAttempts() async throws {
    let repository = try GitTestRepository()
    try repository.write("cross-attempt-index", to: "tracked.txt")
    let headBefore = try repository.git(["rev-parse", "HEAD"]).trimmed
    let repositoryContext = try repository.resolver.loadGitRepository()
    let indexBefore = try Data(contentsOf: repositoryContext.indexURL)
    let firstExecutionId = "index-replacement-exec-1"

    await XCTAssertThrowsErrorAsync(
      try await repository.makeResolver(
        failureInjector: ThrowOnceGitFinalizationFailureInjector(phase: .journal)
      ).execute(
        makeGitCommitInput(
          message: "test: reject cross-attempt index replacement",
          files: ["tracked.txt"],
          stepExecutionId: firstExecutionId
        ),
        context: AdapterExecutionContext()
      )
    ) { _ in }

    try FileManager.default.removeItem(at: repositoryContext.indexURL)
    XCTAssertTrue(FileManager.default.createFile(
      atPath: repositoryContext.indexURL.path,
      contents: indexBefore,
      attributes: [.posixPermissions: 0o600]
    ))

    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(
        makeGitCommitInput(
          message: "test: reject cross-attempt index replacement",
          files: ["tracked.txt"],
          stepExecutionId: "index-replacement-exec-2",
          attempt: 2,
          predecessorStepExecutionId: firstExecutionId
        ),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("index identity changed") == true)
    }
    XCTAssertEqual(try repository.git(["rev-parse", "HEAD"]).trimmed, headBefore)
    XCTAssertEqual(try Data(contentsOf: repositoryContext.indexURL), indexBefore)
    XCTAssertFalse(FileManager.default.fileExists(atPath: repositoryContext.indexLockURL.path))
  }

  func testRetryRejectsWellFormedSemanticJournalTampering() async throws {
    for tamperedField in ["commitMessage", "candidateCommit"] {
      let repository = try GitTestRepository()
      try repository.write("semantic-journal-\(tamperedField)", to: "tracked.txt")
      let headBefore = try repository.git(["rev-parse", "HEAD"]).trimmed
      let indexBefore = try repository.indexData()
      let firstExecutionId = "semantic-\(tamperedField)-exec-1"

      await XCTAssertThrowsErrorAsync(
        try await repository.makeResolver(
          failureInjector: ThrowOnceGitFinalizationFailureInjector(phase: .journal)
        ).execute(
          makeGitCommitInput(
            message: "test: semantic journal validation",
            files: ["tracked.txt"],
            stepExecutionId: firstExecutionId
          ),
          context: AdapterExecutionContext()
        )
      ) { _ in }

      let journalName = try XCTUnwrap(repository.finalizationArtifacts(in: "journals").first)
      let journalURL = repository.finalizationRoot.appendingPathComponent("journals/\(journalName)")
      var journal = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any]
      )
      if tamperedField == "commitMessage" {
        journal[tamperedField] = "test: forged journal message"
      } else {
        journal[tamperedField] = journal["parentCommit"]
      }
      let journalData = try JSONSerialization.data(withJSONObject: journal, options: [.sortedKeys])
      try journalData.write(to: journalURL)

      let linkName = try XCTUnwrap(repository.finalizationArtifacts(in: "links").first)
      let linkURL = repository.finalizationRoot.appendingPathComponent("links/\(linkName)")
      var link = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(contentsOf: linkURL)) as? [String: Any]
      )
      link["journalDigest"] = sha256(journalData)
      try JSONSerialization.data(withJSONObject: link, options: [.sortedKeys]).write(to: linkURL)

      await XCTAssertThrowsErrorAsync(
        try await repository.resolver.execute(
          makeGitCommitInput(
            message: "test: semantic journal validation",
            files: ["tracked.txt"],
            stepExecutionId: "semantic-\(tamperedField)-exec-2",
            attempt: 2,
            predecessorStepExecutionId: firstExecutionId
          ),
          context: AdapterExecutionContext()
        )
      ) { error in
        XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      }
      XCTAssertEqual(try repository.git(["rev-parse", "HEAD"]).trimmed, headBefore)
      XCTAssertEqual(try repository.indexData(), indexBefore)
    }
  }

  func testRetryRejectsCorruptPredecessorLinkWithoutChangingGitState() async throws {
    let repository = try GitTestRepository()
    try repository.write("corrupt-link", to: "tracked.txt")
    let headBefore = try repository.git(["rev-parse", "HEAD"]).trimmed
    let indexBefore = try repository.indexData()
    let firstExecutionId = "corrupt-link-exec-1"

    await XCTAssertThrowsErrorAsync(
      try await repository.makeResolver(
        failureInjector: ThrowOnceGitFinalizationFailureInjector(phase: .journal)
      ).execute(
        makeGitCommitInput(
          message: "test: corrupt predecessor link",
          files: ["tracked.txt"],
          stepExecutionId: firstExecutionId
        ),
        context: AdapterExecutionContext()
      )
    ) { _ in }
    let linkName = try XCTUnwrap(repository.finalizationArtifacts(in: "links").first)
    try Data("not-json".utf8).write(
      to: repository.finalizationRoot.appendingPathComponent("links/\(linkName)")
    )

    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(
        makeGitCommitInput(
          message: "test: corrupt predecessor link",
          files: ["tracked.txt"],
          stepExecutionId: "corrupt-link-exec-2",
          attempt: 2,
          predecessorStepExecutionId: firstExecutionId
        ),
        context: AdapterExecutionContext()
      )
    ) { error in
      let adapterError = error as? AdapterExecutionError
      XCTAssertEqual(adapterError?.code, .policyBlocked)
      XCTAssertEqual(adapterError?.isRetryable, false)
      XCTAssertEqual(adapterError?.message, "git finalization predecessor link is corrupt")
      XCTAssertFalse(adapterError?.message.contains(repository.finalizationRoot.path) == true)
      XCTAssertFalse(adapterError?.message.contains("NSFilePath") == true)
      XCTAssertFalse(adapterError?.message.contains("NSURL") == true)
    }
    XCTAssertEqual(try repository.git(["rev-parse", "HEAD"]).trimmed, headBefore)
    XCTAssertEqual(try repository.indexData(), indexBefore)
  }

  func testRetryRejectsMissingPreparedIndexAfterRefPublication() async throws {
    let repository = try GitTestRepository()
    try repository.write("missing-prepared", to: "tracked.txt")
    let firstExecutionId = "missing-prepared-exec-1"

    await XCTAssertThrowsErrorAsync(
      try await repository.makeResolver(
        failureInjector: ThrowOnceGitFinalizationFailureInjector(phase: .refUpdate)
      ).execute(
        makeGitCommitInput(
          message: "test: missing prepared index",
          files: ["tracked.txt"],
          stepExecutionId: firstExecutionId
        ),
        context: AdapterExecutionContext()
      )
    ) { _ in }
    let preparedName = try XCTUnwrap(repository.finalizationArtifacts(in: "prepared").first)
    try FileManager.default.removeItem(
      at: repository.finalizationRoot.appendingPathComponent("prepared/\(preparedName)")
    )
    let headAfterPublication = try repository.git(["rev-parse", "HEAD"]).trimmed

    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(
        makeGitCommitInput(
          message: "test: missing prepared index",
          files: ["tracked.txt"],
          stepExecutionId: "missing-prepared-exec-2",
          attempt: 2,
          predecessorStepExecutionId: firstExecutionId
        ),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
    }
    XCTAssertEqual(try repository.git(["rev-parse", "HEAD"]).trimmed, headAfterPublication)
  }

  func testRetryRejectsMissingReflogProofAfterRefPublication() async throws {
    let repository = try GitTestRepository()
    try repository.write("missing-reflog", to: "tracked.txt")
    let firstExecutionId = "missing-reflog-exec-1"

    await XCTAssertThrowsErrorAsync(
      try await repository.makeResolver(
        failureInjector: ThrowOnceGitFinalizationFailureInjector(phase: .refUpdate)
      ).execute(
        makeGitCommitInput(
          message: "test: missing reflog proof",
          files: ["tracked.txt"],
          stepExecutionId: firstExecutionId
        ),
        context: AdapterExecutionContext()
      )
    ) { _ in }
    let reflogPath = try repository.git(["rev-parse", "--git-path", "logs/refs/heads/main"]).trimmed
    let reflogURL = reflogPath.hasPrefix("/")
      ? URL(fileURLWithPath: reflogPath)
      : repository.root.appendingPathComponent(reflogPath)
    try FileManager.default.removeItem(at: reflogURL)
    let headAfterPublication = try repository.git(["rev-parse", "HEAD"]).trimmed

    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(
        makeGitCommitInput(
          message: "test: missing reflog proof",
          files: ["tracked.txt"],
          stepExecutionId: "missing-reflog-exec-2",
          attempt: 2,
          predecessorStepExecutionId: firstExecutionId
        ),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("reflog proof") == true)
    }
    XCTAssertEqual(try repository.git(["rev-parse", "HEAD"]).trimmed, headAfterPublication)
  }

  func testConcurrentCanonicalIndexMovementFailsBeforeRefMutation() async throws {
    let repository = try GitTestRepository()
    try repository.write("index-race", to: "tracked.txt")
    let headBefore = try repository.git(["rev-parse", "HEAD"]).trimmed
    let indexURL = try repository.resolver.loadGitRepository().indexURL
    let injector = ActionGitFinalizationFailureInjector(phase: .indexLock) {
      try Data("concurrent-index".utf8).write(to: indexURL)
    }

    await XCTAssertThrowsErrorAsync(
      try await repository.makeResolver(failureInjector: injector).execute(
        makeGitCommitInput(message: "test: index race", files: ["tracked.txt"]),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("canonical index changed") == true)
    }
    XCTAssertEqual(try repository.git(["rev-parse", "HEAD"]).trimmed, headBefore)
    XCTAssertFalse(FileManager.default.fileExists(atPath: indexURL.path + ".lock"))
  }

  func testOwnedIndexLockReplacementFailsBeforeRefMutationAndPreservesForeignLock() async throws {
    let repository = try GitTestRepository()
    try repository.write("lock replacement", to: "tracked.txt")
    let headBefore = try repository.git(["rev-parse", "HEAD"]).trimmed
    let indexBefore = try repository.indexData()
    let lockURL = try repository.indexLockURL()
    let foreignLock = Data("foreign-lock".utf8)
    defer { try? FileManager.default.removeItem(at: lockURL) }
    let injector = ActionGitFinalizationFailureInjector(phase: .indexLock) {
      try FileManager.default.removeItem(at: lockURL)
      try foreignLock.write(to: lockURL, options: [.withoutOverwriting])
    }

    await XCTAssertThrowsErrorAsync(
      try await repository.makeResolver(failureInjector: injector).execute(
        makeGitCommitInput(message: "test: reject lock replacement", files: ["tracked.txt"]),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("lock ownership changed") == true)
    }
    XCTAssertEqual(try repository.git(["rev-parse", "HEAD"]).trimmed, headBefore)
    XCTAssertEqual(try repository.indexData(), indexBefore)
    XCTAssertEqual(try Data(contentsOf: lockURL), foreignLock)
  }

  func testConcurrentRefMovementFailsCompareAndSwapWithoutOverwrite() async throws {
    let repository = try GitTestRepository()
    try repository.write("baseline", to: "baseline.txt")
    _ = try repository.git(["add", "--", "baseline.txt"])
    _ = try repository.git(["commit", "-m", "test: baseline"])
    let expectedParent = try repository.git(["rev-parse", "HEAD"]).trimmed
    let concurrentRevision = try repository.git(["rev-parse", "HEAD^"]).trimmed
    try repository.write("ref-race", to: "tracked.txt")
    let injector = ActionGitFinalizationFailureInjector(phase: .indexLock) {
      _ = try repository.git(["update-ref", "refs/heads/main", concurrentRevision, expectedParent])
    }

    await XCTAssertThrowsErrorAsync(
      try await repository.makeResolver(failureInjector: injector).execute(
        makeGitCommitInput(message: "test: ref race", files: ["tracked.txt"]),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertEqual((error as? AdapterExecutionError)?.isRetryable, true)
    }
    XCTAssertEqual(try repository.git(["rev-parse", "HEAD"]).trimmed, concurrentRevision)
    let indexLockPath = try repository.indexLockURL().path
    XCTAssertFalse(FileManager.default.fileExists(atPath: indexLockPath))
  }

  func testConcurrentBranchSwitchFailsBeforeRefOrIndexPublication() async throws {
    let repository = try GitTestRepository()
    let parent = try repository.git(["rev-parse", "HEAD"]).trimmed
    _ = try repository.git(["branch", "other", parent])
    try repository.write("branch-race", to: "tracked.txt")
    let indexBefore = try repository.indexData()
    let injector = ActionGitFinalizationFailureInjector(phase: .indexLock) {
      _ = try repository.git(["symbolic-ref", "HEAD", "refs/heads/other"])
    }

    await XCTAssertThrowsErrorAsync(
      try await repository.makeResolver(failureInjector: injector).execute(
        makeGitCommitInput(message: "test: branch race", files: ["tracked.txt"]),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.isRetryable, true)
    }
    XCTAssertEqual(try repository.git(["symbolic-ref", "HEAD"]).trimmed, "refs/heads/other")
    XCTAssertEqual(try repository.git(["rev-parse", "refs/heads/main"]).trimmed, parent)
    XCTAssertEqual(try repository.git(["rev-parse", "refs/heads/other"]).trimmed, parent)
    XCTAssertEqual(try repository.indexData(), indexBefore)
    XCTAssertFalse(FileManager.default.fileExists(atPath: try repository.indexLockURL().path))
  }

  func testConcurrentBranchSwitchAfterRefUpdateFailsBeforeIndexPublication() async throws {
    let repository = try GitTestRepository()
    let parent = try repository.git(["rev-parse", "HEAD"]).trimmed
    _ = try repository.git(["branch", "other", parent])
    try repository.write("post-ref-branch-race", to: "tracked.txt")
    let indexBefore = try repository.indexData()
    let injector = ActionGitFinalizationFailureInjector(phase: .refUpdate) {
      _ = try repository.git(["symbolic-ref", "HEAD", "refs/heads/other"])
    }

    await XCTAssertThrowsErrorAsync(
      try await repository.makeResolver(failureInjector: injector).execute(
        makeGitCommitInput(message: "test: post-ref branch race", files: ["tracked.txt"]),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertEqual((error as? AdapterExecutionError)?.isRetryable, true)
    }
    XCTAssertEqual(try repository.git(["symbolic-ref", "HEAD"]).trimmed, "refs/heads/other")
    XCTAssertNotEqual(try repository.git(["rev-parse", "refs/heads/main"]).trimmed, parent)
    XCTAssertEqual(try repository.git(["rev-parse", "refs/heads/other"]).trimmed, parent)
    XCTAssertEqual(try repository.indexData(), indexBefore)
    XCTAssertFalse(FileManager.default.fileExists(atPath: try repository.indexLockURL().path))
  }

  func testConcurrentBranchSwitchAfterIndexPublicationPreventsSuccessOutput() async throws {
    let repository = try GitTestRepository()
    let parent = try repository.git(["rev-parse", "HEAD"]).trimmed
    _ = try repository.git(["branch", "other", parent])
    try repository.write("post-index-branch-race", to: "tracked.txt")
    let injector = ActionGitFinalizationFailureInjector(phase: .indexPublication) {
      _ = try repository.git(["symbolic-ref", "HEAD", "refs/heads/other"])
    }

    await XCTAssertThrowsErrorAsync(
      try await repository.makeResolver(failureInjector: injector).execute(
        makeGitCommitInput(message: "test: post-index branch race", files: ["tracked.txt"]),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertEqual((error as? AdapterExecutionError)?.isRetryable, true)
    }
    XCTAssertEqual(try repository.git(["symbolic-ref", "HEAD"]).trimmed, "refs/heads/other")
    XCTAssertNotEqual(try repository.git(["rev-parse", "refs/heads/main"]).trimmed, parent)
    XCTAssertEqual(try repository.git(["rev-parse", "refs/heads/other"]).trimmed, parent)
  }

  func testConcurrentBranchSwitchAtOutputPublicationPreventsFirstAttemptSuccess() async throws {
    let repository = try GitTestRepository()
    let parent = try repository.git(["rev-parse", "HEAD"]).trimmed
    _ = try repository.git(["branch", "other", parent])
    try repository.write("output-branch-race", to: "tracked.txt")
    let injector = ActionGitFinalizationFailureInjector(phase: .outputPublication) {
      _ = try repository.git(["symbolic-ref", "HEAD", "refs/heads/other"])
    }

    await XCTAssertThrowsErrorAsync(
      try await repository.makeResolver(failureInjector: injector).execute(
        makeGitCommitInput(message: "test: output branch race", files: ["tracked.txt"]),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertEqual((error as? AdapterExecutionError)?.isRetryable, true)
    }
    XCTAssertEqual(try repository.git(["symbolic-ref", "HEAD"]).trimmed, "refs/heads/other")
    XCTAssertNotEqual(try repository.git(["rev-parse", "refs/heads/main"]).trimmed, parent)
    XCTAssertEqual(try repository.git(["rev-parse", "refs/heads/other"]).trimmed, parent)
  }

  func testConcurrentBranchSwitchAtRetryOutputPublicationPreventsSuccess() async throws {
    let repository = try GitTestRepository()
    let parent = try repository.git(["rev-parse", "HEAD"]).trimmed
    _ = try repository.git(["branch", "other", parent])
    try repository.write("retry-output-branch-race", to: "tracked.txt")
    let firstExecutionId = "retry-output-branch-race-1"

    await XCTAssertThrowsErrorAsync(
      try await repository.makeResolver(
        failureInjector: ThrowOnceGitFinalizationFailureInjector(phase: .outputPublication)
      ).execute(
        makeGitCommitInput(
          message: "test: retry output branch race",
          files: ["tracked.txt"],
          stepExecutionId: firstExecutionId
        ),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.isRetryable, true)
    }

    let injector = ActionGitFinalizationFailureInjector(phase: .outputPublication) {
      _ = try repository.git(["symbolic-ref", "HEAD", "refs/heads/other"])
    }
    await XCTAssertThrowsErrorAsync(
      try await repository.makeResolver(failureInjector: injector).execute(
        makeGitCommitInput(
          message: "test: retry output branch race",
          files: ["tracked.txt"],
          stepExecutionId: "retry-output-branch-race-2",
          attempt: 2,
          predecessorStepExecutionId: firstExecutionId
        ),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertEqual((error as? AdapterExecutionError)?.isRetryable, true)
    }
    XCTAssertEqual(try repository.git(["symbolic-ref", "HEAD"]).trimmed, "refs/heads/other")
    XCTAssertNotEqual(try repository.git(["rev-parse", "refs/heads/main"]).trimmed, parent)
    XCTAssertEqual(try repository.git(["rev-parse", "refs/heads/other"]).trimmed, parent)
  }

  func testCommitJournalCarriesAcrossMultipleFailedRecoveryAttempts() async throws {
    let repository = try GitTestRepository()
    try repository.write("multi-retry", to: "tracked.txt")
    let message = "test: multi-attempt recovery"

    await XCTAssertThrowsErrorAsync(
      try await repository.makeResolver(
        failureInjector: ThrowOnceGitFinalizationFailureInjector(phase: .outputPublication)
      ).execute(
        makeGitCommitInput(
          message: message,
          files: ["tracked.txt"],
          stepExecutionId: "multi-retry-exec-1"
        ),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.isRetryable, true)
    }

    await XCTAssertThrowsErrorAsync(
      try await repository.makeResolver(
        failureInjector: ThrowOnceGitFinalizationFailureInjector(phase: .outputPublication)
      ).execute(
        makeGitCommitInput(
          message: message,
          files: ["tracked.txt"],
          stepExecutionId: "multi-retry-exec-2",
          attempt: 2,
          predecessorStepExecutionId: "multi-retry-exec-1"
        ),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.isRetryable, true)
    }

    let recovered = try await repository.resolver.execute(
      makeGitCommitInput(
        message: message,
        files: ["tracked.txt"],
        stepExecutionId: "multi-retry-exec-3",
        attempt: 3,
        predecessorStepExecutionId: "multi-retry-exec-2"
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(gitPayload(recovered.payload)["status"], .string("already-committed"))
    XCTAssertEqual(try repository.git(["rev-list", "--count", "HEAD"]).trimmed, "2")
    XCTAssertEqual(try repository.git(["status", "--short"]).trimmed, "")
    let token = try XCTUnwrap(recovered.runtimeFinalizationToken)
    try await repository.resolver.acknowledgeAcceptedFinalization(token)
    XCTAssertEqual(try repository.finalizationArtifacts(in: "journals"), [])
    XCTAssertEqual(try repository.finalizationArtifacts(in: "prepared"), [])
    XCTAssertEqual(try repository.finalizationArtifacts(in: "links"), [])
  }

  func testCommitJournalCarriesAcrossRetryValidationFailureWithoutSecondCommit() async throws {
    let repository = try GitTestRepository()
    try repository.write("first committed content", to: "tracked.txt")
    let message = "test: validation failure recovery"
    let firstExecutionId = "validation-failure-exec-1"

    await XCTAssertThrowsErrorAsync(
      try await repository.makeResolver(
        failureInjector: ThrowOnceGitFinalizationFailureInjector(phase: .outputPublication)
      ).execute(
        makeGitCommitInput(
          message: message,
          files: ["tracked.txt"],
          stepExecutionId: firstExecutionId
        ),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.isRetryable, true)
    }
    let committedRevision = try repository.git(["rev-parse", "HEAD"]).trimmed

    await XCTAssertThrowsErrorAsync(
      try await repository.makeResolver(
        commandRunner: FailOnceMatchingGitCommandRunner(argument: "write-tree")
      ).execute(
        makeGitCommitInput(
          message: message,
          files: ["tracked.txt"],
          stepExecutionId: "validation-failure-exec-2",
          attempt: 2,
          predecessorStepExecutionId: firstExecutionId
        ),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .providerError)
      XCTAssertEqual((error as? AdapterExecutionError)?.isRetryable, true)
    }
    XCTAssertEqual(try repository.finalizationArtifacts(in: "links").count, 2)

    try repository.write("later uncommitted content", to: "tracked.txt")
    let recovered = try await repository.resolver.execute(
      makeGitCommitInput(
        message: message,
        files: ["tracked.txt"],
        stepExecutionId: "validation-failure-exec-3",
        attempt: 3,
        predecessorStepExecutionId: "validation-failure-exec-2"
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
    XCTAssertEqual(try repository.git(["rev-list", "--count", "HEAD"]).trimmed, "2")
    XCTAssertEqual(try repository.git(["status", "--short"]).trimmed, "M tracked.txt")
  }

  func testCommitJournalCarriesAcrossRetryPreflightFailureWithoutSecondCommit() async throws {
    let repository = try GitTestRepository()
    try repository.write("first preflight content", to: "tracked.txt")
    let message = "test: preflight failure recovery"
    let firstExecutionId = "preflight-failure-exec-1"
    let secondExecutionId = "preflight-failure-exec-2"

    await XCTAssertThrowsErrorAsync(
      try await repository.makeResolver(
        failureInjector: ThrowOnceGitFinalizationFailureInjector(phase: .outputPublication)
      ).execute(
        makeGitCommitInput(
          message: message,
          files: ["tracked.txt"],
          stepExecutionId: firstExecutionId
        ),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.isRetryable, true)
    }
    let committedRevision = try repository.git(["rev-parse", "HEAD"]).trimmed

    await XCTAssertThrowsErrorAsync(
      try await repository.makeResolver(
        commandRunner: FailOnceMatchingGitCommandRunner(argument: "--show-toplevel")
      ).execute(
        makeGitCommitInput(
          message: message,
          files: ["tracked.txt"],
          stepExecutionId: secondExecutionId,
          attempt: 2,
          predecessorStepExecutionId: firstExecutionId
        ),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .providerError)
      XCTAssertEqual((error as? AdapterExecutionError)?.isRetryable, true)
    }
    XCTAssertEqual(try repository.finalizationArtifacts(in: "links").count, 1)

    try repository.write("later preflight content", to: "tracked.txt")
    let recovered = try await repository.resolver.execute(
      makeGitCommitInput(
        message: message,
        files: ["tracked.txt"],
        stepExecutionId: "preflight-failure-exec-3",
        attempt: 3,
        predecessorStepExecutionId: secondExecutionId,
        predecessorStepExecutionIds: [secondExecutionId, firstExecutionId]
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
    XCTAssertEqual(try repository.git(["rev-list", "--count", "HEAD"]).trimmed, "2")
    XCTAssertEqual(try repository.git(["status", "--short"]).trimmed, "M tracked.txt")
  }

  func testRetryRejectsTokenedUpdateAfterBranchMovesAwayAndBack() async throws {
    let repository = try GitTestRepository()
    try repository.write("reset-away-back", to: "tracked.txt")
    let firstExecutionID = "reset-away-back-exec-1"

    await XCTAssertThrowsErrorAsync(
      try await repository.makeResolver(
        failureInjector: ThrowOnceGitFinalizationFailureInjector(phase: .refUpdate)
      ).execute(
        makeGitCommitInput(
          message: "test: reset away and back",
          files: ["tracked.txt"],
          stepExecutionId: firstExecutionID
        ),
        context: AdapterExecutionContext()
      )
    ) { _ in }
    let candidate = try repository.git(["rev-parse", "HEAD"]).trimmed
    let parent = try repository.git(["rev-parse", "HEAD^"]).trimmed
    _ = try repository.git(["update-ref", "refs/heads/main", parent, candidate])
    _ = try repository.git(["update-ref", "refs/heads/main", candidate, parent])

    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(
        makeGitCommitInput(
          message: "test: reset away and back",
          files: ["tracked.txt"],
          stepExecutionId: "reset-away-back-exec-2",
          attempt: 2,
          predecessorStepExecutionId: firstExecutionID
        ),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("reflog proof") == true)
    }
    XCTAssertEqual(try repository.git(["rev-parse", "HEAD"]).trimmed, candidate)
  }

  func testFailedArtifactGarbageCollectionHonorsAge() throws {
    let fixture = try GitFinalizationStoreFixture()
    let oldJournal = try fixture.writeJournal(key: String(repeating: "a", count: 64), executionID: "old")
    let recentJournal = try fixture.writeJournal(key: String(repeating: "b", count: 64), executionID: "recent")
    let orphanJournal = try fixture.writeJournal(key: String(repeating: "c", count: 64), executionID: "orphan")
    try fixture.recordTerminal(oldJournal)
    try fixture.recordTerminal(recentJournal)
    try fixture.recordTerminal(orphanJournal)
    try fixture.setAllArtifactDates(Date(timeIntervalSince1970: 1))
    try fixture.setArtifactDates(for: recentJournal, date: Date())
    try fixture.removeJournalAndPreparedIndex(for: orphanJournal)

    try fixture.store.garbageCollectFailedArtifacts(
      olderThan: Date().addingTimeInterval(-60),
      limit: 10
    )

    XCTAssertFalse(try fixture.contains(journal: oldJournal))
    XCTAssertTrue(try fixture.contains(journal: recentJournal))
    XCTAssertEqual(try fixture.artifacts(in: "links").count, 1)
  }

  func testFailedArtifactGarbageCollectionHonorsLimitAndRemovesCoherentSets() throws {
    let fixture = try GitFinalizationStoreFixture()
    let first = try fixture.writeJournal(key: String(repeating: "a", count: 64), executionID: "first")
    let second = try fixture.writeJournal(key: String(repeating: "b", count: 64), executionID: "second")
    try fixture.recordTerminal(first)
    try fixture.recordTerminal(second)
    try fixture.setAllArtifactDates(Date(timeIntervalSince1970: 1))

    try fixture.store.garbageCollectFailedArtifacts(olderThan: Date(), limit: 1)

    XCTAssertEqual(try fixture.artifacts(in: "journals").count, 1)
    XCTAssertEqual(try fixture.artifacts(in: "prepared").count, 1)
    XCTAssertEqual(try fixture.artifacts(in: "links").count, 1)
    XCTAssertNotEqual(try fixture.contains(journal: first), try fixture.contains(journal: second))
  }

  func testFailedArtifactGarbageCollectionPreservesRecentRetryAlias() throws {
    let fixture = try GitFinalizationStoreFixture()
    let journal = try fixture.writeJournal(key: String(repeating: "c", count: 64), executionID: "original")
    try fixture.recordTerminal(journal)
    try fixture.setAllArtifactDates(Date(timeIntervalSince1970: 1))
    try fixture.store.linkJournal(journal, to: "recent-retry")

    try fixture.store.garbageCollectFailedArtifacts(
      olderThan: Date().addingTimeInterval(-60),
      limit: 10
    )

    XCTAssertTrue(try fixture.contains(journal: journal))
    XCTAssertEqual(try fixture.store.loadJournal(predecessorStepExecutionId: "recent-retry"), journal)
  }
}

final class GitFinalizationStoreFixture {
  let root: URL
  let store: GitFinalizationStore

  init() throws {
    root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/git-finalization-store-tests/\(UUID().uuidString)", isDirectory: true)
    store = GitFinalizationStore(rootDirectory: root)
    try store.prepare()
  }

  deinit {
    try? FileManager.default.removeItem(at: root)
  }

  func writeJournal(
    key: String,
    executionID: String,
    workflowExecutionID: String = "workflow"
  ) throws -> GitCommitJournal {
    let preparedData = Data("prepared-\(key)".utf8)
    _ = try store.writePreparedIndex(preparedData, journalKey: key)
    let journal = GitCommitJournal(
      schemaVersion: 1,
      repository: GitRepositoryIdentity(
        worktreePath: "/repository/\(key)",
        worktreeDevice: 1,
        worktreeInode: 2,
        gitDiscoveryPath: "/repository/\(key)/.git",
        gitDiscoveryDevice: 1,
        gitDiscoveryInode: 3,
        gitDiscoveryFileDigest: nil,
        gitBackpointerPath: nil,
        gitBackpointerDevice: nil,
        gitBackpointerInode: nil,
        gitBackpointerFileDigest: nil,
        gitDirectoryPath: "/repository/\(key)/.git/worktrees/current",
        gitDirectoryDevice: 1,
        gitDirectoryInode: 3,
        commonDirectoryPath: "/repository/\(key)/.git",
        commonDirectoryDevice: 1,
        commonDirectoryInode: 4,
        commonDirectoryLinkPath: "/repository/\(key)/.git/worktrees/current/commondir",
        commonDirectoryLinkDevice: 1,
        commonDirectoryLinkInode: 6,
        commonDirectoryLinkDigest: String(repeating: "a", count: 64),
        objectDirectoryPath: "/repository/\(key)/.git/objects",
        objectDirectoryDevice: 1,
        objectDirectoryInode: 7,
        objectFormat: .sha1,
        indexPath: "/repository/\(key)/.git/worktrees/current/index",
        indexDevice: 1,
        indexInode: 5,
        indexParentPath: "/repository/\(key)/.git/worktrees/current",
        indexParentDevice: 1,
        indexParentInode: 3
      ),
      workflowExecutionId: workflowExecutionID,
      logicalStepId: "commit",
      stepExecutionId: executionID,
      attempt: 1,
      renderedInputDigest: sha256(Data(key.utf8)),
      branchRef: "refs/heads/main",
      parentCommit: String(repeating: "1", count: 40),
      tree: String(repeating: "2", count: 40),
      candidateCommit: String(repeating: "3", count: 40),
      commitMessage: "test",
      committedFiles: ["tracked.txt"],
      authorName: "Riela Test",
      authorEmail: "riela-test@example.invalid",
      committerName: "Riela Test",
      committerEmail: "riela-test@example.invalid",
      originalIndexDigest: sha256(Data("original".utf8)),
      preparedIndexDigest: sha256(preparedData),
      operationToken: key,
      journalKey: key
    )
    try store.writeJournal(journal)
    return journal
  }

  func setAllArtifactDates(_ date: Date) throws {
    for directory in ["journals", "prepared", "links"] {
      for artifact in try artifacts(in: directory) {
        try FileManager.default.setAttributes(
          [.modificationDate: date],
          ofItemAtPath: root.appendingPathComponent("\(directory)/\(artifact)").path
        )
      }
    }
  }

  func recordTerminal(_ journal: GitCommitJournal) throws {
    try store.recordTerminalWorkflowExecution(
      journal.workflowExecutionId,
      stepExecutionIds: [journal.stepExecutionId],
      repository: journal.repository
    )
  }

  func setArtifactDates(for journal: GitCommitJournal, date: Date) throws {
    let paths = [
      "journals/\(journal.journalKey).json",
      "prepared/\(journal.journalKey).index",
      "links/\(sha256(Data(journal.stepExecutionId.utf8))).json"
    ]
    for path in paths {
      try FileManager.default.setAttributes(
        [.modificationDate: date],
        ofItemAtPath: root.appendingPathComponent(path).path
      )
    }
  }

  func contains(journal: GitCommitJournal) throws -> Bool {
    try artifacts(in: "journals").contains(journal.journalKey + ".json")
  }

  func removeJournalAndPreparedIndex(for journal: GitCommitJournal) throws {
    try FileManager.default.removeItem(
      at: root.appendingPathComponent("journals/\(journal.journalKey).json")
    )
    try FileManager.default.removeItem(
      at: root.appendingPathComponent("prepared/\(journal.journalKey).index")
    )
  }

  func artifacts(in directory: String) throws -> [String] {
    try FileManager.default.contentsOfDirectory(
      atPath: root.appendingPathComponent(directory, isDirectory: true).path
    ).sorted()
  }
}
