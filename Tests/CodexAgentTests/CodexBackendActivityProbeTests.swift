import XCTest
import RielaCore
@testable import CodexAgent

final class CodexBackendActivityProbeTests: XCTestCase {
  func testFreshArtifactIsActiveAndStaleArtifactIsStalledSuspect() throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let rollout = try writeRollout(root: root, sessionId: "codex-1", cwd: "/tmp/project")
    let observedAt = Date(timeIntervalSince1970: 2_000_000_000)
    let probe = CodexBackendActivityProbe(codexHome: root.path)

    try FileManager.default.setAttributes(
      [.modificationDate: observedAt.addingTimeInterval(-10)],
      ofItemAtPath: rollout.path
    )
    XCTAssertEqual(try probe.assess(input(observedAt: observedAt)).verdict, .active)

    try FileManager.default.setAttributes(
      [.modificationDate: observedAt.addingTimeInterval(-600)],
      ofItemAtPath: rollout.path
    )
    XCTAssertEqual(try probe.assess(input(observedAt: observedAt)).verdict, .stalledSuspect)
  }

  func testMissingArtifactFailsClosedToUnknown() throws {
    let missingRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/session-observability-tests/missing-\(UUID().uuidString)")
    let probe = CodexBackendActivityProbe(codexHome: missingRoot.path)

    XCTAssertEqual(
      try probe.assess(input(observedAt: Date(timeIntervalSince1970: 2_000_000_000))).verdict,
      .unknown
    )
  }

  func testSQLiteIndexRequiresPresentReadableRolloutArtifact() throws {
    let observedAt = Date(timeIntervalSince1970: 2_000_000_000)
    for invalidArtifact in ["missing", "directory"] {
      let root = try fixtureRoot()
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

      let activity = try CodexBackendActivityProbe(codexHome: root.path).assess(
        input(observedAt: observedAt, backendSessionId: "indexed")
      )

      XCTAssertEqual(activity.verdict, .unknown)
      XCTAssertNil(activity.lastActivityAt)
      XCTAssertEqual(activity.evidence.map(\.kind), [.diagnostic])
      XCTAssertEqual(activity.evidence.first?.path, rollout.path)
    }
  }

  func testSQLiteIndexUsesCurrentRolloutModificationDateInsteadOfCachedUpdatedAt() throws {
    let root = try fixtureRoot()
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

    let activity = try CodexBackendActivityProbe(codexHome: root.path).assess(
      input(observedAt: observedAt, backendSessionId: "indexed")
    )

    XCTAssertEqual(activity.verdict, .stalledSuspect)
    XCTAssertEqual(activity.lastActivityAt, actualActivityAt)
    XCTAssertEqual(activity.ageMs, 600_000)
    XCTAssertEqual(activity.evidence.first?.observedAt, actualActivityAt)
  }

  func testHealthProbeDoesNotCreateSidecarsForIdleWALProviderState() throws {
    let root = try fixtureRoot()
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

    let activity = try CodexBackendActivityProbe(codexHome: root.path).assess(
      input(observedAt: observedAt, backendSessionId: "indexed")
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

  func testTerminalArtifactIsQuietAndReportsEvidenceAndThresholds() throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let observedAt = Date(timeIntervalSince1970: 2_000_000_000)
    let rollout = try writeRollout(root: root, sessionId: "codex-1", cwd: "/tmp/project")
    let activityAt = observedAt.addingTimeInterval(-600)
    try FileManager.default.setAttributes([.modificationDate: activityAt], ofItemAtPath: rollout.path)

    let activity = try CodexBackendActivityProbe(codexHome: root.path).assess(input(
      observedAt: observedAt,
      status: .completed
    ))

    XCTAssertEqual(activity.verdict, .quiet)
    XCTAssertEqual(activity.activeThresholdMs, 30_000)
    XCTAssertEqual(activity.stalledThresholdMs, 180_000)
    XCTAssertEqual(activity.lastActivityAt, activityAt)
    XCTAssertEqual(activity.ageMs, 600_000)
    XCTAssertEqual(activity.evidence.map(\.kind), [.artifact])
    XCTAssertEqual(activity.evidence.first?.path, rollout.path)
    XCTAssertEqual(activity.evidence.first?.ageMs, 600_000)
  }

  func testFallbackCorrelationRequiresOneArtifactInsideLaunchWindow() throws {
    let observedAt = Date(timeIntervalSince1970: 2_000_000_000)
    let executionDate = observedAt.addingTimeInterval(-900)
    let inheritedWorkingDirectory = URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath,
      isDirectory: true
    ).standardizedFileURL.path

    let uniqueRoot = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: uniqueRoot) }
    let uniqueRollout = try writeRollout(
      root: uniqueRoot,
      sessionId: "unique",
      cwd: inheritedWorkingDirectory,
      createdAt: executionDate
    )
    try FileManager.default.setAttributes(
      [.modificationDate: observedAt.addingTimeInterval(-10)],
      ofItemAtPath: uniqueRollout.path
    )
    XCTAssertEqual(
      try CodexBackendActivityProbe(codexHome: uniqueRoot.path)
        .assess(input(
          observedAt: observedAt,
          executionDate: executionDate,
          backendSessionId: nil,
          backendWorkingDirectory: inheritedWorkingDirectory
        ))
        .verdict,
      .active
    )

    let ambiguousRoot = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: ambiguousRoot) }
    _ = try writeRollout(root: ambiguousRoot, sessionId: "first", cwd: "/tmp/project", createdAt: executionDate)
    _ = try writeRollout(
      root: ambiguousRoot,
      sessionId: "second",
      cwd: "/tmp/project",
      createdAt: executionDate.addingTimeInterval(1)
    )
    XCTAssertEqual(
      try CodexBackendActivityProbe(codexHome: ambiguousRoot.path)
        .assess(input(observedAt: observedAt, executionDate: executionDate, backendSessionId: nil))
        .verdict,
      .unknown
    )

    let lateRoot = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: lateRoot) }
    _ = try writeRollout(
      root: lateRoot,
      sessionId: "late",
      cwd: "/tmp/project",
      createdAt: executionDate.addingTimeInterval(61)
    )
    XCTAssertEqual(
      try CodexBackendActivityProbe(codexHome: lateRoot.path)
        .assess(input(observedAt: observedAt, executionDate: executionDate, backendSessionId: nil))
        .verdict,
      .unknown
    )
  }

  func testFallbackCandidateLimitFailsClosedWithoutParsingUnboundedHistory() throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let day = root.appendingPathComponent("sessions/2033/05/18")
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    for index in 0...200 {
      let artifact = day.appendingPathComponent("rollout-2033-05-18T00-00-00-noise-\(index).jsonl")
      try Data("unparsed noise\n".utf8).write(to: artifact)
    }

    let activity = try CodexBackendActivityProbe(codexHome: root.path).assess(input(
      observedAt: Date(timeIntervalSince1970: 2_000_000_000),
      backendSessionId: nil
    ))

    XCTAssertEqual(activity.verdict, .unknown)
    XCTAssertEqual(activity.evidence.map(\.detail), ["Codex artifact candidate limit was exceeded"])
  }

  func testNativeSessionIdUsesTargetedSQLiteLookupWithLargeUnrelatedHistory() throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let observedAt = Date(timeIntervalSince1970: 2_000_000_000)
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
    let day = root.appendingPathComponent("sessions/2033/05/18")
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    for index in 0...250 {
      try Data("noise\n".utf8).write(
        to: day.appendingPathComponent("rollout-2033-05-18T00-00-00-noise-\(index).jsonl")
      )
    }

    let activity = try CodexBackendActivityProbe(codexHome: root.path).assess(input(
      observedAt: observedAt,
      backendSessionId: "target"
    ))

    XCTAssertEqual(activity.verdict, .active)
    XCTAssertEqual(activity.evidence.first?.path, rollout.path)
  }

  private func input(
    observedAt: Date,
    executionDate: Date? = nil,
    backendSessionId: String? = "codex-1",
    backendWorkingDirectory: String = "/tmp/project",
    status: WorkflowStepExecutionStatus = .running
  ) -> SessionBackendActivityProbeInput {
    let executionDate = executionDate ?? observedAt.addingTimeInterval(-900)
    let execution = WorkflowStepExecution(
      executionId: "exec",
      stepId: "step",
      nodeId: "node",
      attempt: 1,
      backend: .codexAgent,
      backendSessionId: backendSessionId,
      backendWorkingDirectory: backendWorkingDirectory,
      status: status,
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
      backend: .codexAgent,
      observedAt: observedAt,
      activeThresholdMs: 30_000,
      stalledThresholdMs: 180_000
    )
  }

  private func fixtureRoot() throws -> URL {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/session-observability-tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func writeRollout(
    root: URL,
    sessionId: String,
    cwd: String,
    createdAt: Date = Date(timeIntervalSince1970: 2_000_000_000)
  ) throws -> URL {
    let day = root.appendingPathComponent("sessions/2033/05/18")
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    let rollout = day.appendingPathComponent("rollout-2033-05-18T00-00-00-\(sessionId).jsonl")
    let timestamp = ISO8601DateFormatter().string(from: createdAt)
    let line = #"{"timestamp":"\#(timestamp)","type":"session_meta","payload":{"meta":{"id":"\#(sessionId)","timestamp":"\#(timestamp)","cwd":"\#(cwd)","cli_version":"1.0","source":"exec"}}}"#
    try Data((line + "\n").utf8).write(to: rollout)
    return rollout
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
        'exec', 'openai', '/tmp/noise', '1.0', 'Noise', '', '', '', '', ''
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
      \(sqliteLiteral(sessionId)), \(sqliteLiteral(rolloutPath)),
      \(sqliteLiteral(formatter.string(from: createdAt))),
      \(sqliteLiteral(formatter.string(from: updatedAt))),
      'exec', 'openai', '/tmp/project', '1.0', 'Indexed session', '', '', '', '', ''
    );
    \(unrelatedRows)
    """
    try runSQLite(root.appendingPathComponent("state").path, sql)
  }

  private func sqliteLiteral(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "''"))'"
  }

  private func removeSQLiteSidecars(databasePath: String) {
    for suffix in ["-shm", "-wal"] {
      try? FileManager.default.removeItem(atPath: databasePath + suffix)
    }
  }
}
