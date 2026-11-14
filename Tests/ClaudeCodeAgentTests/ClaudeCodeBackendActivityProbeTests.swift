import XCTest
import RielaCore
@testable import ClaudeCodeAgent

final class ClaudeCodeBackendActivityProbeTests: XCTestCase {
  func testFreshStreamEvidenceIsActiveAndStaleStreamEvidenceIsStalledSuspect() throws {
    let observedAt = Date(timeIntervalSince1970: 2_000_000_000)
    let missingRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/session-observability-tests/missing-\(UUID().uuidString)")
    let probe = ClaudeCodeBackendActivityProbe(claudeCodeHome: missingRoot.path)

    XCTAssertEqual(
      try probe.assess(input(observedAt: observedAt, eventAge: 10)).verdict,
      .active
    )
    XCTAssertEqual(
      try probe.assess(input(observedAt: observedAt, eventAge: 600)).verdict,
      .stalledSuspect
    )
  }

  func testMissingArtifactAndStreamEvidenceFailsClosedToUnknown() throws {
    let observedAt = Date(timeIntervalSince1970: 2_000_000_000)
    let missingRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/session-observability-tests/missing-\(UUID().uuidString)")
    let probe = ClaudeCodeBackendActivityProbe(claudeCodeHome: missingRoot.path)

    XCTAssertEqual(try probe.assess(input(observedAt: observedAt, eventAge: nil)).verdict, .unknown)
  }

  func testSQLiteIndexRequiresPresentReadableRolloutArtifact() throws {
    let observedAt = Date(timeIntervalSince1970: 2_000_000_000)
    for invalidArtifact in ["missing", "directory"] {
      let root = try makeTemporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let rollout = root.appendingPathComponent("\(invalidArtifact)-rollout.jsonl")
      if invalidArtifact == "directory" {
        try FileManager.default.createDirectory(at: rollout, withIntermediateDirectories: true)
      }
      try writeSQLiteIndex(
        root: root,
        sessionId: "indexed",
        rolloutPath: rollout.path,
        createdAt: observedAt.addingTimeInterval(-900),
        updatedAt: observedAt.addingTimeInterval(-10)
      )

      let activity = try ClaudeCodeBackendActivityProbe(claudeCodeHome: root.path).assess(
        input(observedAt: observedAt, eventAge: nil, backendSessionId: "indexed")
      )

      XCTAssertEqual(activity.verdict, .unknown)
      XCTAssertNil(activity.lastActivityAt)
      XCTAssertEqual(activity.evidence.map(\.kind), [.diagnostic])
      XCTAssertEqual(activity.evidence.first?.path, rollout.path)
    }
  }

  func testSQLiteIndexUsesCurrentRolloutModificationDateInsteadOfCachedUpdatedAt() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let observedAt = Date(timeIntervalSince1970: 2_000_000_000)
    let actualActivityAt = observedAt.addingTimeInterval(-600)
    let rollout = root.appendingPathComponent("indexed-rollout.jsonl")
    try Data("not a discoverable rollout\n".utf8).write(to: rollout)
    try FileManager.default.setAttributes([.modificationDate: actualActivityAt], ofItemAtPath: rollout.path)
    try writeSQLiteIndex(
      root: root,
      sessionId: "indexed",
      rolloutPath: rollout.path,
      createdAt: observedAt.addingTimeInterval(-900),
      updatedAt: observedAt.addingTimeInterval(-10)
    )

    let activity = try ClaudeCodeBackendActivityProbe(claudeCodeHome: root.path).assess(
      input(observedAt: observedAt, eventAge: nil, backendSessionId: "indexed")
    )

    XCTAssertEqual(activity.verdict, .stalledSuspect)
    XCTAssertEqual(activity.lastActivityAt, actualActivityAt)
    XCTAssertEqual(activity.ageMs, 600_000)
    XCTAssertEqual(activity.evidence.first?.observedAt, actualActivityAt)
  }

  func testHealthProbeDoesNotCreateSidecarsForIdleWALProviderState() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let observedAt = Date(timeIntervalSince1970: 2_000_000_000)
    let rollout = root.appendingPathComponent("indexed-rollout.jsonl")
    try Data("indexed only\n".utf8).write(to: rollout)
    try writeSQLiteIndex(
      root: root,
      sessionId: "indexed",
      rolloutPath: rollout.path,
      createdAt: observedAt.addingTimeInterval(-900),
      updatedAt: observedAt.addingTimeInterval(-10)
    )
    let statePath = root.appendingPathComponent("state").path
    try runSQLite(statePath, "PRAGMA journal_mode=WAL; PRAGMA wal_checkpoint(TRUNCATE);")
    removeSQLiteSidecars(databasePath: statePath)
    let before = try XCTUnwrap(
      FileManager.default.attributesOfItem(atPath: statePath)[.modificationDate] as? Date
    )
    let bytesBefore = try Data(contentsOf: URL(fileURLWithPath: statePath))

    let activity = try ClaudeCodeBackendActivityProbe(claudeCodeHome: root.path).assess(
      input(observedAt: observedAt, eventAge: nil, backendSessionId: "indexed")
    )

    let after = try XCTUnwrap(
      FileManager.default.attributesOfItem(atPath: statePath)[.modificationDate] as? Date
    )
    XCTAssertEqual(activity.verdict, .unknown)
    XCTAssertEqual(after, before)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: statePath)), bytesBefore)
    XCTAssertFalse(FileManager.default.fileExists(atPath: statePath + "-shm"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: statePath + "-wal"))
  }

  func testTerminalStreamEvidenceIsQuietAndReportsEvidenceAndThresholds() throws {
    let observedAt = Date(timeIntervalSince1970: 2_000_000_000)
    let missingRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/session-observability-tests/missing-\(UUID().uuidString)")
    let activity = try ClaudeCodeBackendActivityProbe(claudeCodeHome: missingRoot.path).assess(input(
      observedAt: observedAt,
      eventAge: 600,
      status: .completed
    ))

    XCTAssertEqual(activity.verdict, .quiet)
    XCTAssertEqual(activity.activeThresholdMs, 30_000)
    XCTAssertEqual(activity.stalledThresholdMs, 180_000)
    XCTAssertEqual(activity.lastActivityAt, observedAt.addingTimeInterval(-600))
    XCTAssertEqual(activity.ageMs, 600_000)
    XCTAssertEqual(activity.evidence.map(\.kind), [.diagnostic, .backendEvent])
    XCTAssertEqual(activity.evidence.last?.observedAt, observedAt.addingTimeInterval(-600))
    XCTAssertEqual(activity.evidence.last?.ageMs, 600_000)
  }

  func testFallbackCorrelationRequiresOneArtifactInsideLaunchWindow() throws {
    let observedAt = try testDate("2026-06-17T00:15:00Z")
    let executionDate = try testDate("2026-06-17T00:00:00Z")
    let inheritedWorkingDirectory = URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath,
      isDirectory: true
    ).standardizedFileURL.path

    let uniqueRoot = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: uniqueRoot) }
    _ = try writeClaudeRollout(
      home: uniqueRoot,
      sessionId: "unique",
      cwd: inheritedWorkingDirectory
    )
    XCTAssertNotEqual(
      try ClaudeCodeBackendActivityProbe(claudeCodeHome: uniqueRoot.path)
        .assess(input(
          observedAt: observedAt,
          eventAge: nil,
          executionDate: executionDate,
          backendWorkingDirectory: inheritedWorkingDirectory
        ))
        .verdict,
      .unknown
    )

    let ambiguousRoot = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: ambiguousRoot) }
    _ = try writeClaudeRollout(home: ambiguousRoot, sessionId: "first")
    _ = try writeClaudeRollout(home: ambiguousRoot, sessionId: "second")
    XCTAssertEqual(
      try ClaudeCodeBackendActivityProbe(claudeCodeHome: ambiguousRoot.path)
        .assess(input(observedAt: observedAt, eventAge: nil, executionDate: executionDate))
        .verdict,
      .unknown
    )

    let lateRoot = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: lateRoot) }
    _ = try writeClaudeRollout(
      home: lateRoot,
      sessionId: "late",
      createdAt: "2026-06-17T00:01:01.000Z",
      rolloutFileTimestamp: "2026-06-17T00-01-01"
    )
    XCTAssertEqual(
      try ClaudeCodeBackendActivityProbe(claudeCodeHome: lateRoot.path)
        .assess(input(observedAt: observedAt, eventAge: nil, executionDate: executionDate))
        .verdict,
      .unknown
    )
  }

  func testFallbackCorrelationIncludesLegacyProjectArtifacts() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let observedAt = try testDate("2026-06-17T00:15:00Z")
    let executionDate = try testDate("2026-06-17T00:00:00Z")
    let workingDirectory = "/tmp/legacy-project"
    let sessionId = "88487b4c-f3f6-4a49-b59b-d1d4a098425f"
    try writeLegacyClaudeProjectSession(
      home: root,
      projectPath: workingDirectory,
      sessionId: sessionId
    )
    let artifact = root
      .appendingPathComponent("projects/-tmp-legacy-project")
      .appendingPathComponent("\(sessionId).jsonl")
    let probe = ClaudeCodeBackendActivityProbe(claudeCodeHome: root.path)

    let freshActivityAt = observedAt.addingTimeInterval(-10)
    try FileManager.default.setAttributes(
      [.modificationDate: freshActivityAt],
      ofItemAtPath: artifact.path
    )
    let freshWithStaleStream = try probe.assess(input(
      observedAt: observedAt,
      eventAge: 600,
      executionDate: executionDate,
      backendWorkingDirectory: workingDirectory
    ))
    let freshWithoutStream = try probe.assess(input(
      observedAt: observedAt,
      eventAge: nil,
      executionDate: executionDate,
      backendSessionId: sessionId,
      backendWorkingDirectory: workingDirectory
    ))

    XCTAssertEqual(freshWithStaleStream.verdict, .active)
    XCTAssertEqual(freshWithoutStream.verdict, .active)
    XCTAssertEqual(freshWithoutStream.lastActivityAt, freshActivityAt)
    XCTAssertEqual(freshWithoutStream.evidence.first?.path, artifact.path)

    try FileManager.default.setAttributes(
      [.modificationDate: observedAt.addingTimeInterval(-600)],
      ofItemAtPath: artifact.path
    )
    let staleActivity = try probe.assess(input(
      observedAt: observedAt,
      eventAge: nil,
      executionDate: executionDate,
      backendWorkingDirectory: workingDirectory
    ))

    XCTAssertEqual(staleActivity.verdict, .stalledSuspect)
  }

  func testFallbackCandidateLimitFailsClosedWithoutParsingUnboundedHistory() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let day = root.appendingPathComponent("sessions/2026/06/17")
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    for index in 0...200 {
      let artifact = day.appendingPathComponent("rollout-2026-06-17T00-00-00-noise-\(index).jsonl")
      try Data("unparsed noise\n".utf8).write(to: artifact)
    }

    let activity = try ClaudeCodeBackendActivityProbe(claudeCodeHome: root.path).assess(input(
      observedAt: try testDate("2026-06-17T00:15:00Z"),
      eventAge: nil,
      executionDate: try testDate("2026-06-17T00:00:00Z")
    ))

    XCTAssertEqual(activity.verdict, .unknown)
    XCTAssertEqual(activity.evidence.map(\.detail), ["Claude artifact candidate limit was exceeded"])
  }

  func testLegacyProjectFallbackCandidateLimitFailsClosed() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let projectDirectory = root.appendingPathComponent("projects/-tmp-project")
    try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
    for index in 0...200 {
      try Data("noise\n".utf8).write(
        to: projectDirectory.appendingPathComponent("noise-\(index).jsonl")
      )
    }

    let activity = try ClaudeCodeBackendActivityProbe(claudeCodeHome: root.path).assess(input(
      observedAt: try testDate("2026-06-17T00:15:00Z"),
      eventAge: nil,
      executionDate: try testDate("2026-06-17T00:00:00Z")
    ))

    XCTAssertEqual(activity.verdict, .unknown)
    XCTAssertEqual(activity.evidence.map(\.detail), ["Claude artifact candidate limit was exceeded"])
  }

  func testNativeSessionIdUsesTargetedSQLiteLookupWithLargeUnrelatedHistory() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let observedAt = try testDate("2026-06-17T00:15:00Z")
    let rollout = root.appendingPathComponent("indexed-target.jsonl")
    try Data("indexed target\n".utf8).write(to: rollout)
    try FileManager.default.setAttributes(
      [.modificationDate: observedAt.addingTimeInterval(-10)],
      ofItemAtPath: rollout.path
    )
    try writeSQLiteIndex(
      root: root,
      sessionId: "target",
      rolloutPath: rollout.path,
      createdAt: observedAt.addingTimeInterval(-900),
      updatedAt: observedAt.addingTimeInterval(-10),
      unrelatedRecordCount: 250
    )
    let day = root.appendingPathComponent("sessions/2026/06/17")
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    for index in 0...250 {
      try Data("noise\n".utf8).write(
        to: day.appendingPathComponent("rollout-2026-06-17T00-00-00-noise-\(index).jsonl")
      )
    }

    let activity = try ClaudeCodeBackendActivityProbe(claudeCodeHome: root.path).assess(input(
      observedAt: observedAt,
      eventAge: nil,
      backendSessionId: "target"
    ))

    XCTAssertEqual(activity.verdict, .active)
    XCTAssertEqual(activity.evidence.first?.path, rollout.path)
  }

  private func input(
    observedAt: Date,
    eventAge: TimeInterval?,
    executionDate: Date? = nil,
    backendSessionId: String? = nil,
    backendWorkingDirectory: String = "/tmp/project",
    status: WorkflowStepExecutionStatus = .running
  ) -> SessionBackendActivityProbeInput {
    let executionDate = executionDate ?? observedAt.addingTimeInterval(-900)
    let execution = WorkflowStepExecution(
      executionId: "exec",
      stepId: "step",
      nodeId: "node",
      attempt: 1,
      backend: .claudeCodeAgent,
      backendSessionId: backendSessionId,
      backendWorkingDirectory: backendWorkingDirectory,
      status: status,
      lastBackendEventAt: eventAge.map { observedAt.addingTimeInterval(-$0) },
      lastBackendEventType: eventAge == nil ? nil : "stream",
      createdAt: executionDate,
      updatedAt: executionDate
    )
    return SessionBackendActivityProbeInput(
      session: WorkflowSession(
        workflowId: "workflow",
        sessionId: "session",
        status: .running,
        entryStepId: "step",
        currentStepId: "step",
        createdAt: executionDate,
        updatedAt: executionDate,
        executions: [execution]
      ),
      execution: execution,
      backend: .claudeCodeAgent,
      observedAt: observedAt,
      activeThresholdMs: 30_000,
      stalledThresholdMs: 180_000
    )
  }

  private func writeSQLiteIndex(
    root: URL,
    sessionId: String,
    rolloutPath: String,
    createdAt: Date,
    updatedAt: Date,
    unrelatedRecordCount: Int = 0
  ) throws {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let unrelatedRows = (0..<unrelatedRecordCount).map { index in
      """
      INSERT INTO threads VALUES (
        'noise-\(index)', '/missing/noise-\(index).jsonl',
        '\(formatter.string(from: createdAt))', '\(formatter.string(from: updatedAt))',
        'exec', 'anthropic', '/tmp/noise', '1.0', 'Noise', '', '', '', '', ''
      );
      """
    }.joined(separator: "\n")
    let sql = """
    CREATE TABLE threads (
      id TEXT, rollout_path TEXT, created_at TEXT, updated_at TEXT, source TEXT,
      model_provider TEXT, cwd TEXT, cli_version TEXT, title TEXT,
      first_user_message TEXT, archived_at TEXT, git_sha TEXT, git_branch TEXT,
      git_origin_url TEXT
    );
    INSERT INTO threads VALUES (
      \(claudeSQLLiteral(sessionId)), \(claudeSQLLiteral(rolloutPath)),
      \(claudeSQLLiteral(formatter.string(from: createdAt))),
      \(claudeSQLLiteral(formatter.string(from: updatedAt))),
      'exec', 'anthropic', '/tmp/project', '1.0', 'Indexed session', '', '', '', '', ''
    );
    \(unrelatedRows)
    """
    try runSQLite(root.appendingPathComponent("state").path, sql)
  }

  private func runSQLite(_ databasePath: String, _ sql: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [databasePath, sql]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
  }

  private func removeSQLiteSidecars(databasePath: String) {
    for suffix in ["-shm", "-wal"] {
      try? FileManager.default.removeItem(atPath: databasePath + suffix)
    }
  }
}
