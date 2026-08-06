import Foundation
import XCTest
@testable import RielaCLI
@testable import RielaCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class GitWorkflowAddonContractTests: XCTestCase {
  func testCommitSupportsExactTrackedDeletion() async throws {
    let repository = try GitTestRepository()
    try FileManager.default.removeItem(at: repository.root.appendingPathComponent("tracked.txt"))

    let output = try await repository.resolver.execute(
      makeGitCommitInput(message: "test: tracked deletion", files: ["tracked.txt"]),
      context: AdapterExecutionContext()
    )
    let revision = try XCTUnwrap(gitPayload(output.payload)["commitHash"]?.stringValue)

    XCTAssertGitCommitEvidence(
      output.payload,
      status: "committed",
      revision: revision,
      message: "test: tracked deletion",
      files: ["tracked.txt"]
    )
    XCTAssertEqual(try repository.git(["show", "--format=", "--name-status", "HEAD"]).trimmed, "D\ttracked.txt")
  }

  func testCommitRejectsUnchangedTrackedFileWithRefreshedIndexMetadata() async throws {
    let repository = try GitTestRepository()
    let headBefore = try repository.git(["rev-parse", "HEAD"]).trimmed
    let indexBefore = try repository.indexData()

    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(
        makeGitCommitInput(message: "test: unchanged file", files: ["tracked.txt"]),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
    }

    XCTAssertEqual(try repository.git(["rev-parse", "HEAD"]).trimmed, headBefore)
    XCTAssertEqual(try repository.indexData(), indexBefore)
    XCTAssertEqual(try repository.finalizationArtifacts(in: "journals"), [])
  }

  func testCommitRejectsMessageAndFileCollectionBoundsBeforeMutation() async throws {
    let repository = try GitTestRepository()
    let headBefore = try repository.git(["rev-parse", "HEAD"]).trimmed
    let invalidInputs = [
      makeGitCommitInput(message: "   ", files: ["tracked.txt"]),
      makeGitCommitInput(message: String(repeating: "m", count: 4_097), files: ["tracked.txt"]),
      makeGitCommitInput(message: "test: empty files", files: []),
      makeGitCommitInput(
        message: "test: excessive files",
        files: (0...2_048).map { "file-\($0).txt" }
      ),
      makeGitCommitInput(message: "test: duplicate files", files: ["tracked.txt", "tracked.txt"])
    ]

    for input in invalidInputs {
      await XCTAssertThrowsErrorAsync(
        try await repository.resolver.execute(input, context: AdapterExecutionContext())
      ) { error in
        XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      }
    }

    XCTAssertEqual(try repository.git(["rev-parse", "HEAD"]).trimmed, headBefore)
    XCTAssertEqual(try repository.git(["status", "--short"]).trimmed, "")
  }

  func testCommitUsesPerWorktreeMetadataForLinkedWorktree() async throws {
    let primary = try GitTestRepository()
    let linkedRoot = primary.root.deletingLastPathComponent().appendingPathComponent("linked", isDirectory: true)
    _ = try primary.git(["worktree", "add", "-b", "linked-main", linkedRoot.path])
    try "linked change".write(
      to: linkedRoot.appendingPathComponent("tracked.txt"),
      atomically: true,
      encoding: .utf8
    )
    let linkedStore = primary.root.deletingLastPathComponent().appendingPathComponent("linked-finalization")
    let resolver = BuiltinWorkflowAddonResolver(
      environment: ProcessInfo.processInfo.environment,
      workingDirectory: linkedRoot,
      gitFinalizationStore: GitFinalizationStore(rootDirectory: linkedStore)
    )

    let repository = try resolver.loadGitRepository()
    XCTAssertNotEqual(repository.gitDirectory, repository.commonDirectory)
    XCTAssertTrue(repository.indexURL.path.hasPrefix(repository.gitDirectory.path + "/"))

    let output = try await resolver.execute(
      makeGitCommitInput(message: "test: linked worktree", files: ["tracked.txt"]),
      context: AdapterExecutionContext()
    )
    XCTAssertEqual(gitPayload(output.payload)["status"], .string("committed"))
    XCTAssertEqual(
      try GitTestRepository.runGit(["show", "--format=", "--name-only", "HEAD"], at: linkedRoot).trimmed,
      "tracked.txt"
    )
  }

  func testCommitRejectsLinkedWorktreeMetadataRetargetingBeforePublication() async throws {
    let primary = try GitTestRepository()
    let fixtureRoot = primary.root.deletingLastPathComponent()
    let linkedRoot = fixtureRoot.appendingPathComponent("linked-source", isDirectory: true)
    let alternateRoot = fixtureRoot.appendingPathComponent("linked-target", isDirectory: true)
    _ = try primary.git(["worktree", "add", "-b", "linked-source", linkedRoot.path])
    _ = try primary.git(["worktree", "add", "-b", "linked-target", alternateRoot.path])
    try "retargeted change".write(
      to: linkedRoot.appendingPathComponent("tracked.txt"),
      atomically: true,
      encoding: .utf8
    )
    let discoveryURL = linkedRoot.appendingPathComponent(".git")
    let originalDiscovery = try Data(contentsOf: discoveryURL)
    defer { try? originalDiscovery.write(to: discoveryURL, options: [.atomic]) }
    let alternateDiscovery = try Data(contentsOf: alternateRoot.appendingPathComponent(".git"))
    let sourceHead = try GitTestRepository.runGit(["rev-parse", "HEAD"], at: linkedRoot).trimmed
    let targetHead = try GitTestRepository.runGit(["rev-parse", "HEAD"], at: alternateRoot).trimmed
    let indexPath = try GitTestRepository.runGit(["rev-parse", "--git-path", "index"], at: linkedRoot).trimmed
    let indexURL = URL(fileURLWithPath: indexPath)
    let indexBefore = try Data(contentsOf: indexURL)
    let storeRoot = fixtureRoot.appendingPathComponent("retarget-finalization")
    let injector = ContractGitFinalizationFailureInjector(phase: .indexLock) {
      try alternateDiscovery.write(to: discoveryURL, options: [.atomic])
    }
    let resolver = BuiltinWorkflowAddonResolver(
      environment: ProcessInfo.processInfo.environment,
      workingDirectory: linkedRoot,
      gitFinalizationStore: GitFinalizationStore(rootDirectory: storeRoot),
      gitFailureInjector: injector
    )

    await XCTAssertThrowsErrorAsync(
      try await resolver.execute(
        makeGitCommitInput(message: "test: reject metadata retarget", files: ["tracked.txt"]),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("discovery metadata") == true)
    }
    try originalDiscovery.write(to: discoveryURL, options: [.atomic])

    XCTAssertEqual(try GitTestRepository.runGit(["rev-parse", "HEAD"], at: linkedRoot).trimmed, sourceHead)
    XCTAssertEqual(try GitTestRepository.runGit(["rev-parse", "HEAD"], at: alternateRoot).trimmed, targetHead)
    XCTAssertEqual(try Data(contentsOf: indexURL), indexBefore)
    XCTAssertFalse(FileManager.default.fileExists(atPath: indexURL.path + ".lock"))
  }

  func testCommitRejectsTemporaryLinkedWorktreeDiscoveryRetargetDuringPreflight() async throws {
    let primary = try GitTestRepository()
    let fixtureRoot = primary.root.deletingLastPathComponent()
    let linkedRoot = fixtureRoot.appendingPathComponent("preflight-source", isDirectory: true)
    let alternateRoot = fixtureRoot.appendingPathComponent("preflight-target", isDirectory: true)
    _ = try primary.git(["worktree", "add", "-b", "preflight-source", linkedRoot.path])
    _ = try primary.git(["worktree", "add", "-b", "preflight-target", alternateRoot.path])
    try "preflight retarget change".write(
      to: linkedRoot.appendingPathComponent("tracked.txt"),
      atomically: true,
      encoding: .utf8
    )
    let discoveryURL = linkedRoot.appendingPathComponent(".git")
    let originalDiscovery = try Data(contentsOf: discoveryURL)
    let alternateDiscovery = try Data(contentsOf: alternateRoot.appendingPathComponent(".git"))
    let sourceHead = try GitTestRepository.runGit(["rev-parse", "HEAD"], at: linkedRoot).trimmed
    let targetHead = try GitTestRepository.runGit(["rev-parse", "HEAD"], at: alternateRoot).trimmed
    let sourceIndex = URL(fileURLWithPath: try GitTestRepository.runGit(
      ["rev-parse", "--git-path", "index"],
      at: linkedRoot
    ).trimmed)
    let targetIndex = URL(fileURLWithPath: try GitTestRepository.runGit(
      ["rev-parse", "--git-path", "index"],
      at: alternateRoot
    ).trimmed)
    let sourceIndexBefore = try Data(contentsOf: sourceIndex)
    let targetIndexBefore = try Data(contentsOf: targetIndex)
    let runner = DiscoveryRetargetingGitCommandRunner(
      discoveryURL: discoveryURL,
      originalDiscovery: originalDiscovery,
      alternateDiscovery: alternateDiscovery
    )
    defer { try? originalDiscovery.write(to: discoveryURL) }
    let resolver = BuiltinWorkflowAddonResolver(
      environment: ProcessInfo.processInfo.environment,
      workingDirectory: linkedRoot,
      gitCommandRunner: runner,
      gitFinalizationStore: GitFinalizationStore(
        rootDirectory: fixtureRoot.appendingPathComponent("preflight-retarget-finalization")
      )
    )

    await XCTAssertThrowsErrorAsync(
      try await resolver.execute(
        makeGitCommitInput(message: "test: reject preflight retarget", files: ["tracked.txt"]),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("paths changed during preflight") == true)
    }

    XCTAssertEqual(try Data(contentsOf: discoveryURL), originalDiscovery)
    XCTAssertEqual(try GitTestRepository.runGit(["rev-parse", "HEAD"], at: linkedRoot).trimmed, sourceHead)
    XCTAssertEqual(try GitTestRepository.runGit(["rev-parse", "HEAD"], at: alternateRoot).trimmed, targetHead)
    XCTAssertEqual(try Data(contentsOf: sourceIndex), sourceIndexBefore)
    XCTAssertEqual(try Data(contentsOf: targetIndex), targetIndexBefore)
    XCTAssertFalse(FileManager.default.fileExists(atPath: sourceIndex.path + ".lock"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: targetIndex.path + ".lock"))
  }

  func testCommitRejectsSustainedLinkedWorktreeDiscoveryRetargetAcrossBothPreflightPasses() async throws {
    let primary = try GitTestRepository()
    let fixtureRoot = primary.root.deletingLastPathComponent()
    let linkedRoot = fixtureRoot.appendingPathComponent("sustained-source", isDirectory: true)
    let alternateRoot = fixtureRoot.appendingPathComponent("sustained-target", isDirectory: true)
    _ = try primary.git(["worktree", "add", "-b", "sustained-source", linkedRoot.path])
    _ = try primary.git(["worktree", "add", "-b", "sustained-target", alternateRoot.path])
    try "sustained retarget change".write(
      to: linkedRoot.appendingPathComponent("tracked.txt"),
      atomically: true,
      encoding: .utf8
    )
    let discoveryURL = linkedRoot.appendingPathComponent(".git")
    let originalDiscovery = try Data(contentsOf: discoveryURL)
    let alternateDiscovery = try Data(contentsOf: alternateRoot.appendingPathComponent(".git"))
    let sourceHead = try GitTestRepository.runGit(["rev-parse", "HEAD"], at: linkedRoot).trimmed
    let targetHead = try GitTestRepository.runGit(["rev-parse", "HEAD"], at: alternateRoot).trimmed
    let sourceIndex = URL(fileURLWithPath: try GitTestRepository.runGit(
      ["rev-parse", "--git-path", "index"],
      at: linkedRoot
    ).trimmed)
    let targetIndex = URL(fileURLWithPath: try GitTestRepository.runGit(
      ["rev-parse", "--git-path", "index"],
      at: alternateRoot
    ).trimmed)
    let sourceIndexBefore = try Data(contentsOf: sourceIndex)
    let targetIndexBefore = try Data(contentsOf: targetIndex)
    let runner = DiscoveryRetargetingGitCommandRunner(
      discoveryURL: discoveryURL,
      originalDiscovery: originalDiscovery,
      alternateDiscovery: alternateDiscovery,
      restoreAfterIndexDiscoveryCount: 2
    )
    defer { try? originalDiscovery.write(to: discoveryURL) }
    let resolver = BuiltinWorkflowAddonResolver(
      environment: ProcessInfo.processInfo.environment,
      workingDirectory: linkedRoot,
      gitCommandRunner: runner,
      gitFinalizationStore: GitFinalizationStore(
        rootDirectory: fixtureRoot.appendingPathComponent("sustained-retarget-finalization")
      )
    )

    await XCTAssertThrowsErrorAsync(
      try await resolver.execute(
        makeGitCommitInput(message: "test: reject sustained preflight retarget", files: ["tracked.txt"]),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("paths changed during preflight") == true)
    }

    XCTAssertEqual(try Data(contentsOf: discoveryURL), originalDiscovery)
    XCTAssertEqual(try GitTestRepository.runGit(["rev-parse", "HEAD"], at: linkedRoot).trimmed, sourceHead)
    XCTAssertEqual(try GitTestRepository.runGit(["rev-parse", "HEAD"], at: alternateRoot).trimmed, targetHead)
    XCTAssertEqual(try Data(contentsOf: sourceIndex), sourceIndexBefore)
    XCTAssertEqual(try Data(contentsOf: targetIndex), targetIndexBefore)
    XCTAssertFalse(FileManager.default.fileExists(atPath: sourceIndex.path + ".lock"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: targetIndex.path + ".lock"))
  }

  func testCommitRejectsPersistentLinkedWorktreeDiscoveryRetargetBeforePreflight() async throws {
    let primary = try GitTestRepository()
    let fixtureRoot = primary.root.deletingLastPathComponent()
    let linkedRoot = fixtureRoot.appendingPathComponent("persistent-source", isDirectory: true)
    let alternateRoot = fixtureRoot.appendingPathComponent("persistent-target", isDirectory: true)
    _ = try primary.git(["worktree", "add", "-b", "persistent-source", linkedRoot.path])
    _ = try primary.git(["worktree", "add", "-b", "persistent-target", alternateRoot.path])
    try "persistent retarget change".write(
      to: linkedRoot.appendingPathComponent("tracked.txt"),
      atomically: true,
      encoding: .utf8
    )
    let discoveryURL = linkedRoot.appendingPathComponent(".git")
    let originalDiscovery = try Data(contentsOf: discoveryURL)
    let alternateDiscovery = try Data(contentsOf: alternateRoot.appendingPathComponent(".git"))
    let sourceHead = try GitTestRepository.runGit(["rev-parse", "HEAD"], at: linkedRoot).trimmed
    let targetHead = try GitTestRepository.runGit(["rev-parse", "HEAD"], at: alternateRoot).trimmed
    let sourceIndex = URL(fileURLWithPath: try GitTestRepository.runGit(
      ["rev-parse", "--git-path", "index"],
      at: linkedRoot
    ).trimmed)
    let targetIndex = URL(fileURLWithPath: try GitTestRepository.runGit(
      ["rev-parse", "--git-path", "index"],
      at: alternateRoot
    ).trimmed)
    let sourceIndexBefore = try Data(contentsOf: sourceIndex)
    let targetIndexBefore = try Data(contentsOf: targetIndex)
    try alternateDiscovery.write(to: discoveryURL)
    defer { try? originalDiscovery.write(to: discoveryURL) }
    let resolver = BuiltinWorkflowAddonResolver(
      environment: ProcessInfo.processInfo.environment,
      workingDirectory: linkedRoot,
      gitFinalizationStore: GitFinalizationStore(
        rootDirectory: fixtureRoot.appendingPathComponent("persistent-retarget-finalization")
      )
    )

    await XCTAssertThrowsErrorAsync(
      try await resolver.execute(
        makeGitCommitInput(message: "test: reject persistent preflight retarget", files: ["tracked.txt"]),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("backpointer") == true)
    }

    XCTAssertEqual(try Data(contentsOf: discoveryURL), alternateDiscovery)
    XCTAssertEqual(try GitTestRepository.runGit(["rev-parse", "HEAD"], at: linkedRoot).trimmed, targetHead)
    XCTAssertEqual(try GitTestRepository.runGit(["rev-parse", "HEAD"], at: alternateRoot).trimmed, targetHead)
    XCTAssertEqual(try Data(contentsOf: sourceIndex), sourceIndexBefore)
    XCTAssertEqual(try Data(contentsOf: targetIndex), targetIndexBefore)
    XCTAssertFalse(FileManager.default.fileExists(atPath: sourceIndex.path + ".lock"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: targetIndex.path + ".lock"))
    try originalDiscovery.write(to: discoveryURL)
    XCTAssertEqual(try GitTestRepository.runGit(["rev-parse", "HEAD"], at: linkedRoot).trimmed, sourceHead)
  }

  func testCommitRejectsLinkedWorktreeIndexSymlinkToSiblingWorktree() async throws {
    let primary = try GitTestRepository()
    let fixtureRoot = primary.root.deletingLastPathComponent()
    let linkedRoot = fixtureRoot.appendingPathComponent("linked-index-source", isDirectory: true)
    let alternateRoot = fixtureRoot.appendingPathComponent("linked-index-target", isDirectory: true)
    _ = try primary.git(["worktree", "add", "-b", "linked-index-source", linkedRoot.path])
    _ = try primary.git(["worktree", "add", "-b", "linked-index-target", alternateRoot.path])
    try "symlinked index change".write(
      to: linkedRoot.appendingPathComponent("tracked.txt"),
      atomically: true,
      encoding: .utf8
    )
    let sourceGitDirectory = URL(fileURLWithPath: try GitTestRepository.runGit(
      ["rev-parse", "--absolute-git-dir"],
      at: linkedRoot
    ).trimmed)
    let targetGitDirectory = URL(fileURLWithPath: try GitTestRepository.runGit(
      ["rev-parse", "--absolute-git-dir"],
      at: alternateRoot
    ).trimmed)
    let sourceIndex = sourceGitDirectory.appendingPathComponent("index")
    let targetIndex = targetGitDirectory.appendingPathComponent("index")
    let backupIndex = fixtureRoot.appendingPathComponent("linked-index-source.backup")
    let sourceHead = try GitTestRepository.runGit(["rev-parse", "HEAD"], at: linkedRoot).trimmed
    let targetHead = try GitTestRepository.runGit(["rev-parse", "HEAD"], at: alternateRoot).trimmed
    let targetIndexBefore = try Data(contentsOf: targetIndex)
    try FileManager.default.moveItem(at: sourceIndex, to: backupIndex)
    try FileManager.default.createSymbolicLink(at: sourceIndex, withDestinationURL: targetIndex)
    defer {
      try? FileManager.default.removeItem(at: sourceIndex)
      try? FileManager.default.moveItem(at: backupIndex, to: sourceIndex)
    }
    let resolver = BuiltinWorkflowAddonResolver(
      environment: ProcessInfo.processInfo.environment,
      workingDirectory: linkedRoot,
      gitFinalizationStore: GitFinalizationStore(
        rootDirectory: fixtureRoot.appendingPathComponent("index-symlink-finalization")
      )
    )

    await XCTAssertThrowsErrorAsync(
      try await resolver.execute(
        makeGitCommitInput(message: "test: reject sibling index", files: ["tracked.txt"]),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("single-link regular file") == true)
    }
    XCTAssertEqual(try GitTestRepository.runGit(["rev-parse", "HEAD"], at: linkedRoot).trimmed, sourceHead)
    XCTAssertEqual(try GitTestRepository.runGit(["rev-parse", "HEAD"], at: alternateRoot).trimmed, targetHead)
    XCTAssertEqual(try Data(contentsOf: targetIndex), targetIndexBefore)
  }

  func testCommitRejectsLinkedWorktreeIndexRetargetingBeforePublication() async throws {
    let primary = try GitTestRepository()
    let fixtureRoot = primary.root.deletingLastPathComponent()
    let linkedRoot = fixtureRoot.appendingPathComponent("retarget-index-source", isDirectory: true)
    let alternateRoot = fixtureRoot.appendingPathComponent("retarget-index-target", isDirectory: true)
    _ = try primary.git(["worktree", "add", "-b", "retarget-index-source", linkedRoot.path])
    _ = try primary.git(["worktree", "add", "-b", "retarget-index-target", alternateRoot.path])
    try "retargeted index change".write(
      to: linkedRoot.appendingPathComponent("tracked.txt"),
      atomically: true,
      encoding: .utf8
    )
    let sourceGitDirectory = URL(fileURLWithPath: try GitTestRepository.runGit(
      ["rev-parse", "--absolute-git-dir"],
      at: linkedRoot
    ).trimmed)
    let targetGitDirectory = URL(fileURLWithPath: try GitTestRepository.runGit(
      ["rev-parse", "--absolute-git-dir"],
      at: alternateRoot
    ).trimmed)
    let sourceIndex = sourceGitDirectory.appendingPathComponent("index")
    let targetIndex = targetGitDirectory.appendingPathComponent("index")
    let sourceIndexBefore = try Data(contentsOf: sourceIndex)
    let targetIndexBefore = try Data(contentsOf: targetIndex)
    let sourceHead = try GitTestRepository.runGit(["rev-parse", "HEAD"], at: linkedRoot).trimmed
    let targetHead = try GitTestRepository.runGit(["rev-parse", "HEAD"], at: alternateRoot).trimmed
    defer {
      try? FileManager.default.removeItem(at: sourceIndex)
      try? sourceIndexBefore.write(to: sourceIndex, options: [.atomic])
    }
    let injector = ContractGitFinalizationFailureInjector(phase: .indexLock) {
      try FileManager.default.removeItem(at: sourceIndex)
      try FileManager.default.createSymbolicLink(at: sourceIndex, withDestinationURL: targetIndex)
    }
    let resolver = BuiltinWorkflowAddonResolver(
      environment: ProcessInfo.processInfo.environment,
      workingDirectory: linkedRoot,
      gitFinalizationStore: GitFinalizationStore(
        rootDirectory: fixtureRoot.appendingPathComponent("index-retarget-finalization")
      ),
      gitFailureInjector: injector
    )

    await XCTAssertThrowsErrorAsync(
      try await resolver.execute(
        makeGitCommitInput(message: "test: reject index retarget", files: ["tracked.txt"]),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("per-worktree index") == true)
    }
    XCTAssertEqual(try GitTestRepository.runGit(["rev-parse", "HEAD"], at: linkedRoot).trimmed, sourceHead)
    XCTAssertEqual(try GitTestRepository.runGit(["rev-parse", "HEAD"], at: alternateRoot).trimmed, targetHead)
    XCTAssertEqual(try Data(contentsOf: targetIndex), targetIndexBefore)
    XCTAssertFalse(FileManager.default.fileExists(atPath: sourceIndex.path + ".lock"))
  }

  func testCommitRejectsLinkedWorktreeCommonDirectoryRetargetBeforeCanonicalIndexRead() async throws {
    let primary = try GitTestRepository()
    let attacker = try GitTestRepository()
    let fixtureRoot = primary.root.deletingLastPathComponent()
    let linkedRoot = fixtureRoot.appendingPathComponent("commondir-source", isDirectory: true)
    _ = try primary.git(["worktree", "add", "-b", "commondir-source", linkedRoot.path])
    try "commondir retarget".write(
      to: linkedRoot.appendingPathComponent("tracked.txt"),
      atomically: true,
      encoding: .utf8
    )
    let gitDirectory = URL(fileURLWithPath: try GitTestRepository.runGit(
      ["rev-parse", "--absolute-git-dir"],
      at: linkedRoot
    ).trimmed)
    let commondirURL = gitDirectory.appendingPathComponent("commondir")
    let originalCommondir = try Data(contentsOf: commondirURL)
    let sourceHead = try GitTestRepository.runGit(["rev-parse", "HEAD"], at: linkedRoot).trimmed
    let attackerHead = try attacker.git(["rev-parse", "HEAD"]).trimmed
    defer { try? originalCommondir.write(to: commondirURL, options: [.atomic]) }
    let injector = ContractGitFinalizationFailureInjector(phase: .canonicalIndexRead) {
      try Data("\(attacker.root.appendingPathComponent(".git").path)\n".utf8)
        .write(to: commondirURL, options: [.atomic])
    }
    let resolver = BuiltinWorkflowAddonResolver(
      environment: ProcessInfo.processInfo.environment,
      workingDirectory: linkedRoot,
      gitFinalizationStore: GitFinalizationStore(
        rootDirectory: fixtureRoot.appendingPathComponent("commondir-retarget-finalization")
      ),
      gitFailureInjector: injector
    )

    await XCTAssertThrowsErrorAsync(
      try await resolver.execute(
        makeGitCommitInput(message: "test: reject commondir retarget", files: ["tracked.txt"]),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("common-directory binding") == true)
    }
    try originalCommondir.write(to: commondirURL, options: [.atomic])
    XCTAssertEqual(try GitTestRepository.runGit(["rev-parse", "HEAD"], at: linkedRoot).trimmed, sourceHead)
    XCTAssertEqual(try attacker.git(["rev-parse", "HEAD"]).trimmed, attackerHead)
  }

  func testCommitRejectsEscapedObjectDirectoryBeforeMutation() async throws {
    let repository = try GitTestRepository()
    let attacker = try GitTestRepository()
    let objectDirectory = repository.root.appendingPathComponent(".git/objects", isDirectory: true)
    let backupDirectory = repository.root.deletingLastPathComponent()
      .appendingPathComponent("source-objects", isDirectory: true)
    let attackerObjects = attacker.root.appendingPathComponent(".git/objects", isDirectory: true)
    let headBefore = try repository.git(["rev-parse", "HEAD"]).trimmed
    let attackerHead = try attacker.git(["rev-parse", "HEAD"]).trimmed
    try FileManager.default.moveItem(at: objectDirectory, to: backupDirectory)
    try FileManager.default.createSymbolicLink(at: objectDirectory, withDestinationURL: attackerObjects)
    var needsRestore = true
    defer {
      if needsRestore {
        try? FileManager.default.removeItem(at: objectDirectory)
        try? FileManager.default.moveItem(at: backupDirectory, to: objectDirectory)
      }
    }

    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(
        makeGitCommitInput(message: "test: reject escaped objects", files: ["tracked.txt"]),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("object directory") == true)
    }
    try FileManager.default.removeItem(at: objectDirectory)
    try FileManager.default.moveItem(at: backupDirectory, to: objectDirectory)
    needsRestore = false
    XCTAssertEqual(try repository.git(["rev-parse", "HEAD"]).trimmed, headBefore)
    XCTAssertEqual(try attacker.git(["rev-parse", "HEAD"]).trimmed, attackerHead)
  }

  func testCommitRejectsCanonicalIndexSymlinkSwapBeforeFirstRead() async throws {
    let repository = try GitTestRepository()
    try repository.write("index symlink swap", to: "tracked.txt")
    let indexURL = try repository.resolver.loadGitRepository().indexURL
    let originalIndex = try Data(contentsOf: indexURL)
    let externalIndex = repository.root.deletingLastPathComponent().appendingPathComponent("external.index")
    try originalIndex.write(to: externalIndex)
    let externalBefore = try Data(contentsOf: externalIndex)
    let headBefore = try repository.git(["rev-parse", "HEAD"]).trimmed
    defer {
      try? FileManager.default.removeItem(at: indexURL)
      try? originalIndex.write(to: indexURL, options: [.atomic])
    }
    let injector = ContractGitFinalizationFailureInjector(phase: .canonicalIndexRead) {
      try FileManager.default.removeItem(at: indexURL)
      try FileManager.default.createSymbolicLink(at: indexURL, withDestinationURL: externalIndex)
    }

    await XCTAssertThrowsErrorAsync(
      try await repository.makeResolver(failureInjector: injector).execute(
        makeGitCommitInput(message: "test: reject index symlink swap", files: ["tracked.txt"]),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("index") == true)
    }
    XCTAssertEqual(try Data(contentsOf: externalIndex), externalBefore)
    XCTAssertEqual(try repository.git(["rev-parse", "HEAD"]).trimmed, headBefore)
  }

  func testCommitRejectsCanonicalIndexFIFOWithoutBlockingBeforeFirstRead() async throws {
    let repository = try GitTestRepository()
    try repository.write("index fifo swap", to: "tracked.txt")
    let indexURL = try repository.resolver.loadGitRepository().indexURL
    let originalIndex = try Data(contentsOf: indexURL)
    let headBefore = try repository.git(["rev-parse", "HEAD"]).trimmed
    defer {
      try? FileManager.default.removeItem(at: indexURL)
      try? originalIndex.write(to: indexURL, options: [.atomic])
    }
    let injector = ContractGitFinalizationFailureInjector(phase: .canonicalIndexRead) {
      try FileManager.default.removeItem(at: indexURL)
      guard mkfifo(indexURL.path, 0o600) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
      }
    }
    let startedAt = Date()

    await XCTAssertThrowsErrorAsync(
      try await repository.makeResolver(failureInjector: injector).execute(
        makeGitCommitInput(message: "test: reject index fifo swap", files: ["tracked.txt"]),
        context: AdapterExecutionContext(deadline: Date().addingTimeInterval(2))
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("index") == true)
    }
    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
    XCTAssertEqual(try repository.git(["rev-parse", "HEAD"]).trimmed, headBefore)
  }

  func testGitAddonRejectsFinalizationStoreInsideRepository() async throws {
    let repository = try GitTestRepository()
    let storeRoot = repository.root.appendingPathComponent("runtime-store", isDirectory: true)
    let resolver = BuiltinWorkflowAddonResolver(
      environment: ProcessInfo.processInfo.environment,
      workingDirectory: repository.root,
      gitFinalizationStore: GitFinalizationStore(rootDirectory: storeRoot)
    )

    await XCTAssertThrowsErrorAsync(
      try await resolver.execute(
        makeGitCommitInput(message: "test: confined store", files: ["tracked.txt"]),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("outside the repository") == true)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: storeRoot.path))
  }

  func testGitAddonRejectsFinalizationStoreSymlinkResolvingInsideRepository() async throws {
    let repository = try GitTestRepository()
    let target = repository.root.appendingPathComponent("runtime-store-target", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let linkedStore = repository.root.deletingLastPathComponent()
      .appendingPathComponent("runtime-store-link", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: linkedStore, withDestinationURL: target)
    let resolver = BuiltinWorkflowAddonResolver(
      environment: ProcessInfo.processInfo.environment,
      workingDirectory: repository.root,
      gitFinalizationStore: GitFinalizationStore(rootDirectory: linkedStore)
    )

    await XCTAssertThrowsErrorAsync(
      try await resolver.execute(
        makeGitCommitInput(message: "test: symlinked store", files: ["tracked.txt"]),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("outside the repository") == true)
    }
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
  }

  func testGitAddonRejectsNonemptyRuntimeHooksDirectory() async throws {
    let repository = try GitTestRepository()
    let store = GitFinalizationStore(rootDirectory: repository.finalizationRoot)
    try store.prepare()
    let hook = store.hooksDirectory.appendingPathComponent("pre-push")
    try "#!/bin/sh\nexit 99\n".write(to: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)

    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(
        makeGitCommitInput(message: "test: nonempty hooks", files: ["tracked.txt"]),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("hooks directory must be empty") == true)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: hook.path))
  }

  func testPushRejectsUnsafeTransportFormsBeforeNetworkAccess() async throws {
    let unsafeURLs = [
      "https://example.invalid/repository.git?token=secret",
      "ssh://user:secret@example.invalid/repository.git",
      "file://example.invalid/repository.git",
      "unknown://example.invalid/repository.git"
    ]

    for unsafeURL in unsafeURLs {
      let repository = try GitTestRepository(withBareRemote: true)
      _ = try repository.git(["remote", "set-url", "--push", "origin", unsafeURL])

      await XCTAssertThrowsErrorAsync(
        try await repository.resolver.execute(makeGitPushInput(repository: repository), context: AdapterExecutionContext())
      ) { error in
        XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked, unsafeURL)
      }
    }
  }

  func testPushRejectsConfiguredSSHCommandBeforeNetworkAccess() async throws {
    let repository = try GitTestRepository(withBareRemote: true)
    _ = try repository.git([
      "remote", "set-url", "--push", "origin", "ssh://git@example.invalid/repository.git"
    ])
    _ = try repository.git(["config", "core.sshCommand", "sh -c unsafe"])

    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(makeGitPushInput(repository: repository), context: AdapterExecutionContext())
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("SSH command") == true)
    }
  }

  func testGitFailureDiagnosticsAreBoundedAndDoNotLeakProviderOutput() async throws {
    let repository = try GitTestRepository()
    let secret = "https://user:secret@example.invalid/private.git"
    let runner = SensitiveFailingGitCommandRunner(output: String(repeating: secret, count: 50_000))

    await XCTAssertThrowsErrorAsync(
      try await repository.makeResolver(commandRunner: runner).execute(
        makeGitCommitInput(message: "test: bounded diagnostic", files: ["tracked.txt"]),
        context: AdapterExecutionContext()
      )
    ) { error in
      let adapterError = error as? AdapterExecutionError
      XCTAssertEqual(adapterError?.code, .providerError)
      XCTAssertEqual(adapterError?.isRetryable, true)
      XCTAssertLessThan(adapterError?.message.utf8.count ?? .max, 256)
      XCTAssertFalse(adapterError?.message.contains(secret) == true)
    }
  }

  func testFoundationGitRunnerStopsAtOutputLimit() throws {
    let repository = try GitTestRepository()
    let largePath = "large-output.txt"
    try Data(repeating: 0x61, count: 1_048_577).write(
      to: repository.root.appendingPathComponent(largePath)
    )
    _ = try repository.git(["add", "--", largePath])
    _ = try repository.git(["commit", "-m", "test: large output"])

    XCTAssertThrowsError(
      try FoundationGitCommandRunner().run(GitCommandInvocation(
        executableURL: GitExecutablePolicy.versionOneURL,
        arguments: ["show", "HEAD:\(largePath)"],
        workingDirectory: repository.root,
        environment: ProcessInfo.processInfo.environment,
        standardInput: nil
      ))
    ) { error in
      guard case GitCommandRunnerError.outputTooLarge = error else {
        return XCTFail("expected outputTooLarge, got \(error)")
      }
    }
  }

  func testFoundationGitRunnerTerminatesProcessGroupAtDeadline() throws {
    let repository = try GitTestRepository()
    let startedAt = Date()

    XCTAssertThrowsError(
      try FoundationGitCommandRunner().run(GitCommandInvocation(
        executableURL: GitExecutablePolicy.versionOneURL,
        arguments: ["-c", "alias.riela-hang=!sleep 30 & wait", "riela-hang"],
        workingDirectory: repository.root,
        environment: ProcessInfo.processInfo.environment,
        standardInput: nil,
        deadline: Date().addingTimeInterval(0.2)
      ))
    ) { error in
      guard case GitCommandRunnerError.deadlineExceeded = error else {
        return XCTFail("expected deadlineExceeded, got \(error)")
      }
    }
    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 3)
  }

  func testFoundationGitRunnerClampsDeadlineBeyondInt32Milliseconds() throws {
    let repository = try GitTestRepository()
    let longDeadline = Date().addingTimeInterval(Double(Int32.max) / 1_000 + 60)

    let result = try FoundationGitCommandRunner().run(GitCommandInvocation(
      executableURL: GitExecutablePolicy.versionOneURL,
      arguments: ["-c", "alias.riela-delay=!sleep 0.1", "riela-delay"],
      workingDirectory: repository.root,
      environment: ProcessInfo.processInfo.environment,
      standardInput: nil,
      deadline: longDeadline
    ))

    XCTAssertEqual(result.exitCode, 0)
  }

  func testFoundationGitRunnerRejectsNonFiniteDeadline() throws {
    let repository = try GitTestRepository()

    XCTAssertThrowsError(
      try FoundationGitCommandRunner().run(GitCommandInvocation(
        executableURL: GitExecutablePolicy.versionOneURL,
        arguments: ["--version"],
        workingDirectory: repository.root,
        environment: ProcessInfo.processInfo.environment,
        standardInput: nil,
        deadline: Date(timeIntervalSince1970: .infinity)
      ))
    ) { error in
      guard case GitCommandRunnerError.deadlineExceeded = error else {
        return XCTFail("expected deadlineExceeded, got \(error)")
      }
    }
  }

  func testGitAddonPropagatesWorkflowDeadlineToCommandRunner() async throws {
    let repository = try GitTestRepository()
    let runner = DeadlineCapturingGitCommandRunner()
    let deadline = Date().addingTimeInterval(30)

    await XCTAssertThrowsErrorAsync(
      try await repository.makeResolver(commandRunner: runner).execute(
        makeGitCommitInput(message: "test: deadline", files: ["tracked.txt"]),
        context: AdapterExecutionContext(deadline: deadline)
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .timeout)
    }
    XCTAssertEqual(try XCTUnwrap(runner.deadline).timeIntervalSince1970, deadline.timeIntervalSince1970, accuracy: 0.001)
  }
}

private final class ContractGitFinalizationFailureInjector:
  GitFinalizationFailureInjecting,
  @unchecked Sendable {
  private let lock = NSLock()
  private let phase: GitFinalizationFailurePhase
  private let action: () throws -> Void
  private var didRun = false

  init(phase: GitFinalizationFailurePhase, action: @escaping () throws -> Void) {
    self.phase = phase
    self.action = action
  }

  func check(_ phase: GitFinalizationFailurePhase) throws {
    let shouldRun = lock.withLock { () -> Bool in
      guard phase == self.phase, !didRun else { return false }
      didRun = true
      return true
    }
    if shouldRun {
      try action()
    }
  }
}

func makeGitCommitInput(
  message: String,
  files: [String],
  workflowExecutionId: String = "git-contract-session",
  stepExecutionId: String = UUID().uuidString,
  attempt: Int = 1,
  predecessorStepExecutionId: String? = nil,
  predecessorStepExecutionIds: [String]? = nil
) -> WorkflowAddonExecutionInput {
  return WorkflowAddonExecutionInput(
    workflowId: "git-contract-test",
    stepId: "commit",
    nodeId: "commit",
    addon: WorkflowNodeAddonRef(
      name: BuiltinGitAddon.commit.rawValue,
      version: "1",
      config: [
        "allowCommit": .bool(true),
        "commitMessageTemplate": .string("{{message}}"),
        "committedFilesTemplate": .string("{{files}}")
      ]
    ),
    variables: [
      "message": .string(message),
      "files": .array(files.map(JSONValue.string))
    ],
    executionIdentity: WorkflowAddonExecutionIdentity(
      workflowExecutionId: workflowExecutionId,
      stepExecutionId: stepExecutionId,
      attempt: attempt,
      predecessorStepExecutionId: predecessorStepExecutionId,
      predecessorStepExecutionIds: predecessorStepExecutionIds
    )
  )
}

func makeGitPushInput(
  repository: GitTestRepository,
  expectedCommitHash: String? = nil
) throws -> WorkflowAddonExecutionInput {
  let expectedCommitHash = try expectedCommitHash ?? repository.git(["rev-parse", "HEAD"]).trimmed
  return WorkflowAddonExecutionInput(
    workflowId: "git-contract-test",
    stepId: "push",
    nodeId: "push",
    addon: WorkflowNodeAddonRef(
      name: BuiltinGitAddon.push.rawValue,
      version: "1",
      config: [
        "allowPush": .bool(true),
        "expectedCommitHashTemplate": .string("{{expectedCommitHash}}")
      ]
    ),
    variables: ["expectedCommitHash": .string(expectedCommitHash)],
    executionIdentity: WorkflowAddonExecutionIdentity(
      workflowExecutionId: "git-contract-session",
      stepExecutionId: UUID().uuidString,
      attempt: 1
    )
  )
}

private struct SensitiveFailingGitCommandRunner: GitCommandRunning {
  var output: String

  func run(_: GitCommandInvocation) throws -> GitCommandResult {
    GitCommandResult(exitCode: 128, output: output)
  }
}

private final class DeadlineCapturingGitCommandRunner: GitCommandRunning, @unchecked Sendable {
  private let lock = NSLock()
  private var capturedDeadline: Date?

  var deadline: Date? {
    lock.withLock { capturedDeadline }
  }

  func run(_ invocation: GitCommandInvocation) throws -> GitCommandResult {
    lock.withLock {
      capturedDeadline = invocation.deadline
    }
    throw GitCommandRunnerError.deadlineExceeded
  }
}

private final class DiscoveryRetargetingGitCommandRunner: GitCommandRunning, @unchecked Sendable {
  private let lock = NSLock()
  private let discoveryURL: URL
  private let originalDiscovery: Data
  private let alternateDiscovery: Data
  private let restoreAfterIndexDiscoveryCount: Int
  private let underlying = FoundationGitCommandRunner()
  private var didRetarget = false
  private var retargetingActive = false
  private var indexDiscoveryCount = 0

  init(
    discoveryURL: URL,
    originalDiscovery: Data,
    alternateDiscovery: Data,
    restoreAfterIndexDiscoveryCount: Int = 1
  ) {
    self.discoveryURL = discoveryURL
    self.originalDiscovery = originalDiscovery
    self.alternateDiscovery = alternateDiscovery
    self.restoreAfterIndexDiscoveryCount = restoreAfterIndexDiscoveryCount
  }

  func run(_ invocation: GitCommandInvocation) throws -> GitCommandResult {
    if invocation.arguments.contains("--absolute-git-dir") {
      try lock.withLock {
        guard !didRetarget else { return }
        try alternateDiscovery.write(to: discoveryURL)
        didRetarget = true
        retargetingActive = true
      }
    }
    do {
      let result = try underlying.run(invocation)
      if invocation.arguments.contains("--git-path"), invocation.arguments.last == "index" {
        try recordIndexDiscoveryAndRestoreIfNeeded()
      }
      return result
    } catch {
      try? restoreIfNeeded()
      throw error
    }
  }

  private func recordIndexDiscoveryAndRestoreIfNeeded() throws {
    try lock.withLock {
      guard retargetingActive else { return }
      indexDiscoveryCount += 1
      guard indexDiscoveryCount >= restoreAfterIndexDiscoveryCount else { return }
      try originalDiscovery.write(to: discoveryURL)
      retargetingActive = false
    }
  }

  private func restoreIfNeeded() throws {
    try lock.withLock {
      guard retargetingActive else { return }
      try originalDiscovery.write(to: discoveryURL)
      retargetingActive = false
    }
  }
}
