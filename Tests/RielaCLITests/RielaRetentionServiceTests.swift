import Foundation
import XCTest
import RielaCore
import RielaSQLite
@testable import RielaCLI

final class RielaRetentionServiceTests: XCTestCase {
  private var roots: [URL] = []

  override func tearDown() {
    roots.reversed().forEach { try? FileManager.default.removeItem(at: $0) }
    roots = []
    super.tearDown()
  }

  func testAutomaticWithoutPolicyUsesDefaultsAndSkipsGeneratedSweep() throws {
    let home = try makeRoot()
    let snapshot = try makeOldSnapshot(home: home)
    let log = try makeOldLog(home: home)
    let report = try service(now: Date(timeIntervalSince1970: 4_000_000)).run(request(home: home))
    XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
    XCTAssertEqual(report.targets.first?.generated.removedEntryCount, 0)
    XCTAssertEqual(report.targets.first?.results.policySource, .builtInDefault)
  }

  func testDefaultAgePrunesOldTerminalAndFollowsMessages() throws {
    let home = try makeRoot()
    let database = try makeSessionDatabase(home: home)
    try insertSession("old", database: database)
    try insertSession("recent", database: database)
    let now = Date(timeIntervalSince1970: 4_000_000)
    let recent = ISO8601DateFormatter().string(from: now.addingTimeInterval(-29 * 86_400))
    try database.execute("UPDATE workflow_runtime_snapshots SET updated_at=? WHERE workflow_execution_id='recent'", bindings: [.text(recent)])
    let preview = try service(now: now).run(request(home: home, trigger: .manual, dryRun: true))
    XCTAssertEqual(preview.targets.first?.results.selectedCount, 1)
    XCTAssertFalse(try database.tableExists("session_retention_tombstones"))
    let report = try service(now: now).run(request(home: home))
    XCTAssertEqual(report.targets.first?.results.removedCount, 1)
    XCTAssertEqual(try database.query("SELECT workflow_execution_id FROM workflow_runtime_snapshots").first?["workflow_execution_id"], "recent")
    XCTAssertEqual(try database.query("SELECT workflow_execution_id FROM workflow_messages").first?["workflow_execution_id"], "recent")
  }

  func testDefaultRetentionProtectsResumableAndLockedSessions() throws {
    let home = try makeRoot()
    let database = try makeSessionDatabase(home: home)
    for id in ["old", "running", "suspended", "created", "locked", "tree-root", "tree-child"] {
      try insertSession(id, database: database)
    }
    for status in ["running", "suspended", "created"] {
      try database.execute("UPDATE workflow_runtime_snapshots SET session_status=? WHERE workflow_execution_id=?",
        bindings: [.text(status), .text(status)])
    }
    try database.execute("""
      UPDATE workflow_runtime_snapshots SET parent_session_id='tree-root', root_session_id='tree-root',
        session_status='running' WHERE workflow_execution_id='tree-child'
      """)
    let registry = SessionExecutionLockRegistry(sessionStoreRoot: home.appendingPathComponent(".riela/sessions").path)
    try registry.acquire(sessionId: "locked")
    defer { registry.release(sessionId: "locked") }
    let report = try service(now: Date(timeIntervalSince1970: 4_000_000)).run(request(home: home))
    XCTAssertEqual(report.targets.first?.results.removedCount, 1)
    let remaining = Set(try database.query("SELECT workflow_execution_id FROM workflow_runtime_snapshots")
      .compactMap { $0["workflow_execution_id"] })
    let expected = Set(["running", "suspended", "created", "locked", "tree-root", "tree-child"])
    XCTAssertEqual(remaining, expected)
    let messages = Set(try database.query("SELECT workflow_execution_id FROM workflow_messages")
      .compactMap { $0["workflow_execution_id"] })
    XCTAssertEqual(messages, expected)
    XCTAssertGreaterThan(report.targets.first?.results.protected["nonterminalOrConflictingStatus"] ?? 0, 0)
  }

  func testAutomaticPrunesOldLogAndWritesCompletedStamp() throws {
    let home = try makeRoot()
    let log = try makeOldLog(home: home)
    try writeConfig(home: home, json: #"{"retention":{"logs":{"maxAgeDays":14}}}"#)
    let now = Date(timeIntervalSince1970: 2_000_000)
    let report = try service(now: now).run(request(home: home))
    XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
    XCTAssertEqual(report.targets.first?.logs.removedCount, 1)
    let stamp = try XCTUnwrap(RetentionRunStamp.read(stateDirectory: home.appendingPathComponent(".riela/retention").path))
    XCTAssertEqual(stamp.lastStatus, "completed")
    XCTAssertEqual(stamp.lastAttemptAt, now)
  }

  func testAutomaticSecondRunIsThrottled() throws {
    let home = try makeRoot()
    _ = try makeOldLog(home: home)
    try writeConfig(home: home, json: #"{"retention":{"logs":{"maxAgeDays":14}}}"#)
    let firstTime = Date(timeIntervalSince1970: 2_000_000)
    _ = try service(now: firstTime).run(request(home: home))
    let second = try service(now: firstTime.addingTimeInterval(300)).run(request(home: home))
    XCTAssertEqual(second.targets.first?.status, "skippedThrottled")
  }

  func testAutomaticPolicyCanBeDisabled() throws {
    let home = try makeRoot()
    _ = try makeOldLog(home: home)
    try writeConfig(home: home, json: #"{"retention":{"automatic":false,"logs":{"maxAgeDays":14}}}"#)
    let report = try service(now: Date()).run(request(home: home))
    XCTAssertTrue(report.targets.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".riela/retention").path))
  }

  func testEnvironmentDisablesAutomaticButManualPrunesDefaultAge() throws {
    let home = try makeRoot()
    let database = try makeSessionDatabase(home: home)
    try insertSession("old", database: database)
    let now = Date(timeIntervalSince1970: 4_000_000)
    let environment = ["HOME": home.path, "RIELA_RETENTION_AUTOMATIC": "0"]
    let automatic = RielaRetentionRequest(trigger: .automatic, homeDirectory: home, projectDirectory: nil,
      environment: environment, scope: .user, overrides: .init(), dryRun: false)
    let manual = RielaRetentionRequest(trigger: .manual, homeDirectory: home, projectDirectory: nil,
      environment: environment, scope: .user, overrides: .init(), dryRun: false)
    XCTAssertTrue(try service(now: now).run(automatic).targets.isEmpty)
    XCTAssertEqual(try database.query("SELECT * FROM workflow_runtime_snapshots").count, 1)
    XCTAssertEqual(try service(now: now).run(manual).targets.first?.results.removedCount, 1)
    XCTAssertTrue(try database.query("SELECT * FROM workflow_runtime_snapshots").isEmpty)
  }

  func testKeepForeverOverrideIsRejected() throws {
    let home = try makeRoot()
    try writeConfig(home: home, json: #"{"retention":{"logs":{"keepForever":true}}}"#)
    XCTAssertThrowsError(try service(now: Date()).run(request(home: home, trigger: .manual,
      overrides: RielaRetentionOverrides(logsMaxAgeDays: 14)))) { error in
      XCTAssertEqual(error as? RielaRetentionUsageError, .keepForeverOverride(category: "logs"))
    }
  }

  func testManualOverrideWorksWithoutConfiguredPolicy() throws {
    let home = try makeRoot()
    let log = try makeOldLog(home: home)
    let report = try service(now: Date(timeIntervalSince1970: 2_000_000)).run(request(home: home,
      trigger: .manual, overrides: RielaRetentionOverrides(logsMaxAgeDays: 14)))
    XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
    XCTAssertEqual(report.targets.first?.logs.state, .active)
    XCTAssertEqual(report.targets.first?.results.state, .active)
  }

  func testDryRunDoesNotDeleteOrWriteThrottleStamp() throws {
    let home = try makeRoot()
    let log = try makeOldLog(home: home)
    try writeConfig(home: home, json: #"{"retention":{"logs":{"maxAgeDays":14}}}"#)
    let original = try FileManager.default.attributesOfItem(atPath: log.path)
    let report = try service(now: Date(timeIntervalSince1970: 2_000_000)).run(request(home: home, dryRun: true))
    XCTAssertEqual(report.targets.first?.logs.selectedCount, 1)
    XCTAssertEqual(report.targets.first?.logs.removedCount, 0)
    XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: log.path))[.size] as? NSNumber,
      original[.size] as? NSNumber)
    XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".riela/retention").path))
  }

  func testProjectPolicyOverridesUserPolicy() throws {
    let home = try makeRoot()
    let project = try makeRoot()
    let userLog = try makeOldLog(home: home)
    let projectLog = try makeOldLog(home: project)
    try writeConfig(home: home, json: #"{"retention":{"logs":{"maxAgeDays":14}}}"#)
    try writeConfig(home: project, json: #"{"retention":{"logs":{"keepForever":true}}}"#)
    let report = try service(now: Date(timeIntervalSince1970: 2_000_000)).run(request(home: home, project: project))
    XCTAssertFalse(FileManager.default.fileExists(atPath: userLog.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: projectLog.path))
    XCTAssertEqual(report.targets.first(where: { $0.kind == .project })?.logs.state, .keepForever)
  }

  func testCorruptProjectStoreDoesNotStopUserTarget() throws {
    let home = try makeRoot()
    let project = try makeRoot()
    let userLog = try makeOldLog(home: home)
    let corruptDatabase = project.appendingPathComponent(".riela/sessions/runtime-records/runtime-message-log.sqlite")
    try FileManager.default.createDirectory(at: corruptDatabase.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not a sqlite database".utf8).write(to: corruptDatabase)
    try writeConfig(home: home, json: #"{"retention":{"results":{"maxAgeDays":1},"logs":{"maxAgeDays":14}}}"#)
    let report = try service(now: Date(timeIntervalSince1970: 2_000_000)).run(request(home: home, project: project))
    XCTAssertFalse(FileManager.default.fileExists(atPath: userLog.path))
    XCTAssertEqual(report.targets.first(where: { $0.kind == .user })?.status, "completed")
    XCTAssertEqual(report.targets.first(where: { $0.kind == .project })?.status, "failed")
    XCTAssertFalse(report.targets.first(where: { $0.kind == .project })?.warnings.isEmpty ?? true)
  }

  func testUnsafeTargetIsReportedWithoutCreatingState() throws {
    let home = try makeRoot()
    let target = home.appendingPathComponent(".riela", isDirectory: true)
    try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: home.path)
    let report = try service(now: Date()).run(request(home: home, trigger: .manual))
    XCTAssertEqual(report.targets.first?.status, "skippedUnsafePath")
    XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("retention").path))
  }

  func testManualNoPolicyIncludesDefaultCategoryReports() throws {
    let home = try makeRoot()
    _ = try makeRielaRoot(home)
    let report = try service(now: Date()).run(request(home: home, trigger: .manual))
    XCTAssertEqual(report.targets.first?.results.state, .active)
    XCTAssertEqual(report.targets.first?.messages.state, .notConfigured)
    XCTAssertEqual(report.targets.first?.logs.state, .active)
  }

  func testHeldTargetLockSkipsAutomaticAndFailsManual() throws {
    let home = try makeRoot()
    _ = try makeOldLog(home: home)
    try writeConfig(home: home, json: #"{"retention":{"logs":{"maxAgeDays":14}}}"#)
    let state = home.appendingPathComponent(".riela/retention").path
    let held = try XCTUnwrap(RetentionTargetLock.tryAcquire(stateDirectory: state))
    let now = Date(timeIntervalSince1970: 2_000_000)
    let automatic = try service(now: now).run(request(home: home))
    XCTAssertEqual(automatic.targets.first?.status, "skippedBusy")
    let manual = try service(now: now).run(request(home: home, trigger: .manual))
    XCTAssertEqual(manual.targets.first?.status, "busy")
    XCTAssertTrue(manual.hasFailure)
    withExtendedLifetime(held) {}
  }

  func testResultsKeepForeverLeavesSessionsAndMessagesWhileLogsPrune() throws {
    let home = try makeRoot()
    let log = try makeOldLog(home: home)
    let database = try makeSessionDatabase(home: home)
    try insertSession("kept", database: database)
    try writeConfig(home: home, json: #"{"retention":{"results":{"keepForever":true},"logs":{"maxAgeDays":14}}}"#)
    let report = try service(now: Date(timeIntervalSince1970: 2_000_000)).run(request(home: home))
    XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
    XCTAssertEqual(try database.query("SELECT count(*) AS count FROM workflow_runtime_snapshots").first?["count"], "1")
    XCTAssertEqual(try database.query("SELECT count(*) AS count FROM workflow_messages").first?["count"], "1")
    XCTAssertEqual(report.targets.first?.results.state, .keepForever)
    XCTAssertEqual(report.targets.first?.messages.state, .notConfigured)
  }

  func testMessagesKeepForeverAllowsResultsPruneAndKeepsLogs() throws {
    let home = try makeRoot()
    let log = try makeOldLog(home: home)
    let database = try makeSessionDatabase(home: home)
    try insertSession("expired", database: database)
    try writeConfig(home: home, json: #"{"retention":{"results":{"maxAgeDays":1},"messages":{"keepForever":true},"logs":{"keepForever":true}}}"#)
    let report = try service(now: Date(timeIntervalSince1970: 2_000_000)).run(request(home: home))
    XCTAssertTrue(try database.query("SELECT * FROM workflow_runtime_snapshots").isEmpty)
    XCTAssertEqual(try database.query("SELECT count(*) AS count FROM workflow_messages").first?["count"], "1")
    XCTAssertTrue(FileManager.default.fileExists(atPath: log.path))
    XCTAssertEqual(report.targets.first?.results.removedCount, 1)
    XCTAssertEqual(report.targets.first?.messages.state, .keepForever)
    XCTAssertEqual(report.targets.first?.logs.state, .keepForever)
  }

  func testManualRunReclaimsRuntimeDatabaseOnceThroughInjectedFreeSpace() throws {
    let home = try makeRoot()
    let database = try makeSessionDatabase(home: home)
    try insertSession("expired", database: database)
    try writeConfig(home: home, json: #"{"retention":{"results":{"maxAgeDays":1}}}"#)
    let probe = FreeSpaceProbe()
    let service = RielaRetentionService(clock: { Date(timeIntervalSince1970: 2_000_000) }, freeSpace: { path in
      probe.record(path)
      return 0
    })
    let report = try service.run(request(home: home, trigger: .manual))
    let runtime = report.targets.first?.reclamation.filter { $0.database.hasSuffix("runtime-message-log.sqlite") } ?? []
    XCTAssertEqual(report.targets.first?.results.removedCount, 1)
    XCTAssertEqual(runtime.count, 1, "the runtime database must be reclaimed exactly once per pass")
    XCTAssertEqual(runtime.first?.action, "deferredInsufficientSpace")
    XCTAssertEqual(probe.count, 1, "the injected free-space probe must reach the reclaimer")
  }

  func testResultsMaxAgePrunesGeneratedSnapshotWithoutInformationalFailure() throws {
    let home = try makeRoot()
    let snapshot = try makeOldSnapshot(home: home)
    try writeConfig(home: home, json: #"{"retention":{"results":{"maxAgeDays":7}}}"#)
    let report = try service(now: Date(timeIntervalSince1970: 2_000_000)).run(request(home: home))
    XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path))
    let target = try XCTUnwrap(report.targets.first)
    XCTAssertGreaterThanOrEqual(target.generated.removedEntryCount, 1)
    XCTAssertEqual(target.status, "completed")
    XCTAssertTrue(target.warnings.isEmpty, "\(target.warnings)")
    XCTAssertFalse(report.hasFailure)
  }

  func testDryRunKeepsGeneratedSnapshotAndStaysCompleted() throws {
    let home = try makeRoot()
    let snapshot = try makeOldSnapshot(home: home)
    try writeConfig(home: home, json: #"{"retention":{"results":{"maxAgeDays":7}}}"#)
    let report = try service(now: Date(timeIntervalSince1970: 2_000_000)).run(request(home: home, dryRun: true))
    XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path))
    let target = try XCTUnwrap(report.targets.first)
    XCTAssertEqual(target.status, "completed")
    XCTAssertTrue(target.warnings.isEmpty, "\(target.warnings)")
  }

  func testBusyReclamationIsWarningNotFailure() throws {
    let home = try makeRoot()
    let database = try makeSessionDatabase(home: home)
    try writeConfig(home: home, json: #"{"retention":{"results":{"maxAgeDays":1}}}"#)
    let writer = try SQLiteDatabase.open(path: CLIWorkflowSessionStore.defaultDatabasePath(
      rootDirectory: home.appendingPathComponent(".riela/sessions", isDirectory: true).path),
      options: SQLiteOpenOptions(enableWAL: false, requireJSONB: false))
    // The reclaimer opens its own connection before probing free space, so taking the write lock from the
    // injected probe lets retention itself succeed while the conversion step meets a concurrent writer.
    let holder = WriteLockHolder(writer)
    defer { holder.release() }
    let service = RielaRetentionService(clock: { Date(timeIntervalSince1970: 2_000_000) }, freeSpace: { _ in
      holder.acquire()
      return Int64.max / 4
    })
    let report = try service.run(request(home: home, trigger: .manual))
    withExtendedLifetime(database) {}
    let target = try XCTUnwrap(report.targets.first)
    let runtime = target.reclamation.filter { $0.database.hasSuffix("runtime-message-log.sqlite") }
    XCTAssertEqual(runtime.count, 1)
    XCTAssertEqual(runtime.first?.action, "busy")
    XCTAssertNotNil(runtime.first?.warning)
    XCTAssertTrue(target.warnings.contains { $0 == runtime.first?.warning })
    XCTAssertEqual(target.status, "completed")
    XCTAssertFalse(report.hasFailure)
  }

  func testManualWithoutPolicyReportsDefaults() throws {
    let home = try makeRoot()
    _ = try makeRielaRoot(home)
    let report = try untouchedStoreService().run(request(home: home, trigger: .manual, dryRun: true))
    let target = try XCTUnwrap(report.targets.first)
    XCTAssertEqual(target.results.policy?.maxAgeDays, 30)
    XCTAssertEqual(target.results.policySource, .builtInDefault)
    XCTAssertEqual(target.messages.state, .notConfigured)
    XCTAssertEqual(target.logs.policy?.maxAgeDays, 30)
  }

  func testLogsOnlyPolicyDoesNotTouchSessionStore() throws {
    let home = try makeRoot()
    let log = try makeOldLog(home: home)
    let database = try makeSessionDatabase(home: home)
    try insertSession("kept", database: database)
    let lock = try makeOrphanLock(home: home)
    try writeConfig(home: home,
      json: #"{"retention":{"results":{"keepForever":true},"messages":{"keepForever":true},"logs":{"maxAgeDays":14}}}"#)
    let report = try untouchedStoreService().run(request(home: home, trigger: .manual))
    let target = try XCTUnwrap(report.targets.first)
    XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path))
    try assertSessionStoreUntouched(database, target: target)
    XCTAssertEqual(target.results.state, .keepForever)
    XCTAssertEqual(target.messages.state, .keepForever)
  }

  func testDefinitionKeepVersionsPrunesDefinitionHistoryAndHonorsDryRun() throws {
    let home = try makeRoot()
    let sessionRoot = home.appendingPathComponent(".riela/sessions", isDirectory: true).path
    let store = WorkflowDefinitionStore(rootDirectory: sessionRoot, now: { Date(timeIntervalSince1970: 2_000_000) })
    var previous: String?
    for index in 0..<3 {
      let document = Data(#"{"runtime":{"revision":\#(index)}}"#.utf8)
      guard case let .created(version, _) = try store.commit(WorkflowDefinitionWrite(
        workflowName: "demo", operation: index == 0 ? .seed : .update, documentData: document,
        documentDigest: JSONCanonical.sha256Hex(document), sourceDirectory: "/demo", sourceScope: "user",
        provenance: "test", actor: WorkflowDefinitionActor(kind: .user), reason: "change \(index)",
        expectedCurrentVersionId: previous
      )) else { return XCTFail("expected a new version") }
      previous = version.versionId
    }
    try writeConfig(home: home, json: #"{"retention":{"definitions":{"keepVersions":1}}}"#)

    let preview = try untouchedStoreService().run(request(home: home, trigger: .manual, dryRun: true))
    XCTAssertEqual(preview.targets.first?.definitions?.removedVersionCount, 1)
    XCTAssertEqual(try store.history(workflowName: "demo").count, 3)

    let report = try untouchedStoreService().run(request(home: home, trigger: .manual))
    let definitions = try XCTUnwrap(report.targets.first?.definitions)
    XCTAssertEqual(definitions.keepVersions, 1)
    XCTAssertEqual(definitions.workflowCount, 1)
    XCTAssertEqual(definitions.removedVersionCount, 1)
    XCTAssertEqual(report.targets.first?.status, "completed")
    let newest = try XCTUnwrap(store.history(workflowName: "demo").first)
    XCTAssertEqual(newest.operation, .prune)
    XCTAssertEqual(newest.actor.id, "riela-retention")
  }

  func testManualGCPreservesSavedPerWorkflowDefinitionRetention() throws {
    let home = try makeRoot()
    let sessionRoot = home.appendingPathComponent(".riela/sessions", isDirectory: true).path
    let oldDate = Date(timeIntervalSince1970: 2_000_000)
    let store = WorkflowDefinitionStore(rootDirectory: sessionRoot, now: { oldDate })
    var previous: String?
    for index in 0..<12 {
      let document = Data(#"{"runtime":{"revision":\#(index)}}"#.utf8)
      guard case let .created(version, _) = try store.commit(WorkflowDefinitionWrite(
        workflowName: "default-window", operation: index == 0 ? .seed : .update, documentData: document,
        documentDigest: JSONCanonical.sha256Hex(document), sourceDirectory: "/default-window", sourceScope: "user",
        provenance: "test", actor: WorkflowDefinitionActor(kind: .user), reason: "change \(index)",
        expectedCurrentVersionId: previous, historyRetention: 50
      )) else { return XCTFail("expected a new version") }
      previous = version.versionId
    }

    let report = try untouchedStoreService().run(request(home: home, trigger: .manual))
    XCTAssertEqual(report.targets.first?.definitions?.keepVersions, 10)
    XCTAssertEqual(report.targets.first?.definitions?.removedVersionCount, 0)
    XCTAssertEqual(try store.history(workflowName: "default-window").filter { $0.operation == .prune }.count, 0)
    XCTAssertEqual(try store.retainedHistoryGenerations(workflowName: "default-window"), 50)
  }

  func testManualGCResolvesDefinitionHistoryAliasAndProjectPrecedence() throws {
    let home = try makeRoot()
    let project = try makeRoot()
    let sessionRoot = home.appendingPathComponent(".riela/sessions", isDirectory: true).path
    let store = WorkflowDefinitionStore(rootDirectory: sessionRoot, now: { Date(timeIntervalSince1970: 2_000_000) })
    var previous: String?
    for index in 0..<12 {
      let document = Data(#"{"runtime":{"revision":\#(index)}}"#.utf8)
      guard case let .created(version, _) = try store.commit(WorkflowDefinitionWrite(
        workflowName: "alias-window", operation: index == 0 ? .seed : .update, documentData: document,
        documentDigest: JSONCanonical.sha256Hex(document), sourceDirectory: "/alias-window", sourceScope: "user",
        provenance: "test", actor: WorkflowDefinitionActor(kind: .user), reason: "change \(index)",
        expectedCurrentVersionId: previous, defaultHistoryRetention: 100
      )) else { return XCTFail("expected a new version") }
      previous = version.versionId
    }
    let projectStore = WorkflowDefinitionStore(rootDirectory: project.appendingPathComponent(".riela/sessions", isDirectory: true).path,
      now: { Date(timeIntervalSince1970: 2_000_000) })
    var projectPrevious: String?
    for index in 0..<12 {
      let document = Data(#"{"runtime":{"revision":\#(index)}}"#.utf8)
      guard case let .created(version, _) = try projectStore.commit(WorkflowDefinitionWrite(
        workflowName: "project-window", operation: index == 0 ? .seed : .update, documentData: document,
        documentDigest: JSONCanonical.sha256Hex(document), sourceDirectory: "/project-window", sourceScope: "project",
        provenance: "test", actor: WorkflowDefinitionActor(kind: .user), reason: "change \(index)",
        expectedCurrentVersionId: projectPrevious, defaultHistoryRetention: 100
      )) else { return XCTFail("expected a new project definition version") }
      projectPrevious = version.versionId
    }
    try writeConfig(home: home, json: #"{"workflowDefinitions":{"historyRetention":50}}"#)
    try writeConfig(home: project, json: #"{"retention":{"logs":{"maxAgeDays":7}}}"#)
    let report = try untouchedStoreService().run(request(home: home, project: project, trigger: .manual))
    let userTarget = try XCTUnwrap(report.targets.first { $0.kind == .user })
    let projectTarget = try XCTUnwrap(report.targets.first { $0.kind == .project })
    XCTAssertEqual(userTarget.definitions?.keepVersions, 50)
    XCTAssertEqual(projectTarget.definitions?.keepVersions, 50, "project category policy does not replace user definition retention")
    XCTAssertEqual(userTarget.definitions?.removedVersionCount, 0)
    try writeConfig(home: project, json: #"{"workflowDefinitions":{"historyRetention":25},"retention":{"logs":{"maxAgeDays":7}}}"#)
    let overridden = try untouchedStoreService().run(request(home: home, project: project, trigger: .manual))
    XCTAssertEqual(overridden.targets.first { $0.kind == .project }?.definitions?.keepVersions, 25)
  }

  func testManualGCWithZeroDefinitionRetentionKeepsAllHistory() throws {
    let home = try makeRoot()
    let sessionRoot = home.appendingPathComponent(".riela/sessions", isDirectory: true).path
    let store = WorkflowDefinitionStore(rootDirectory: sessionRoot, now: { Date(timeIntervalSince1970: 2_000_000) })
    var previous: String?
    for index in 0..<12 {
      let document = Data(#"{"runtime":{"revision":\#(index)}}"#.utf8)
      guard case let .created(version, _) = try store.commit(WorkflowDefinitionWrite(
        workflowName: "unlimited-window", operation: index == 0 ? .seed : .update, documentData: document,
        documentDigest: JSONCanonical.sha256Hex(document), sourceDirectory: "/unlimited-window", sourceScope: "user",
        provenance: "test", actor: WorkflowDefinitionActor(kind: .user), reason: "change \(index)",
        expectedCurrentVersionId: previous, defaultHistoryRetention: 100
      )) else { return XCTFail("expected a new version") }
      previous = version.versionId
    }
    try writeConfig(home: home, json: #"{"workflowDefinitions":{"historyRetention":0}}"#)
    let definitionDatabase = try SQLiteDatabase.open(
      path: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: sessionRoot),
      mode: .readOnly, options: .readOnlyDefault
    )
    let dataVersionBefore = try definitionDatabase.query("PRAGMA data_version").first?["data_version"]
    let report = try untouchedStoreService().run(request(home: home, trigger: .manual))
    XCTAssertEqual(report.targets.first?.definitions?.keepVersions, 0)
    XCTAssertEqual(report.targets.first?.definitions?.removedVersionCount, 0)
    XCTAssertEqual(try store.history(workflowName: "unlimited-window").filter { $0.operation == .prune }.count, 0)
    XCTAssertEqual(try definitionDatabase.query("PRAGMA data_version").first?["data_version"], dataVersionBefore)
  }

  private func untouchedStoreService() -> RielaRetentionService {
    // Ample free space: a full VACUUM conversion would happen if reclamation ran.
    RielaRetentionService(clock: { Date(timeIntervalSince1970: 2_000_000) }, freeSpace: { _ in Int64.max / 4 })
  }

  private func makeOrphanLock(home: URL) throws -> URL {
    let directory = home.appendingPathComponent(".riela/sessions/runtime-records/execution-locks", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let lock = directory.appendingPathComponent("orphan-session.lock")
    try Data().write(to: lock)
    return lock
  }

  private func assertSessionStoreUntouched(_ database: SQLiteDatabase, target: RielaRetentionTargetReport) throws {
    XCTAssertEqual(try database.query("PRAGMA auto_vacuum").first?["auto_vacuum"], "0")
    XCTAssertTrue(try database.query("SELECT name FROM sqlite_master WHERE name = 'session_retention_tombstones'").isEmpty)
    XCTAssertEqual(try database.query("SELECT count(*) AS count FROM workflow_runtime_snapshots").first?["count"], "1")
    XCTAssertEqual(target.status, "completed")
    XCTAssertNil(target.orphanLocks)
    XCTAssertTrue(target.reclamation.isEmpty)
  }

  private func makeOldSnapshot(home: URL) throws -> URL {
    let rielaRoot = try makeRielaRoot(home)
    let snapshot = rielaRoot.appendingPathComponent("workflow-history/demo/snapshots/snapshot-old", isDirectory: true)
    let manifest = snapshot.appendingPathComponent("manifest.json")
    try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
    try Data("test".utf8).write(to: manifest)
    let oldDate = Date(timeIntervalSince1970: 1_000)
    try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: manifest.path)
    try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: snapshot.path)
    return snapshot
  }

  private final class WriteLockHolder: @unchecked Sendable {
    private let lock = NSLock()
    private let database: SQLiteDatabase
    private var held = false

    init(_ database: SQLiteDatabase) { self.database = database }

    func acquire() {
      lock.lock()
      defer { lock.unlock() }
      guard !held else { return }
      held = true
      try? database.execute("BEGIN IMMEDIATE")
    }

    func release() {
      lock.lock()
      defer { lock.unlock() }
      guard held else { return }
      held = false
      try? database.execute("ROLLBACK")
    }
  }

  private func request(
    home: URL,
    project: URL? = nil,
    trigger: RielaRetentionTrigger = .automatic,
    overrides: RielaRetentionOverrides = .init(),
    dryRun: Bool = false
  ) -> RielaRetentionRequest {
    RielaRetentionRequest(trigger: trigger, homeDirectory: home, projectDirectory: project,
      environment: ["HOME": home.path], scope: project == nil ? .user : .all,
      overrides: overrides, dryRun: dryRun)
  }

  private func service(now: Date) -> RielaRetentionService { RielaRetentionService(clock: { now }, freeSpace: { _ in 0 }) }

  private func makeOldLog(home: URL) throws -> URL {
    let root = try makeRielaRoot(home).appendingPathComponent("logs", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let log = root.appendingPathComponent("old.jsonl")
    try Data("log".utf8).write(to: log)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: log.path)
    return log
  }

  @discardableResult
  private func makeRielaRoot(_ home: URL) throws -> URL {
    let root = home.appendingPathComponent(".riela", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func writeConfig(home: URL, json: String) throws {
    let root = try makeRielaRoot(home)
    try Data(json.utf8).write(to: root.appendingPathComponent("config.json"))
  }

  private func makeSessionDatabase(home: URL) throws -> SQLiteDatabase {
    let store = home.appendingPathComponent(".riela/sessions", isDirectory: true).path
    let databasePath = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: store)
    try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: databasePath).deletingLastPathComponent().path,
      withIntermediateDirectories: true)
    let database = try SQLiteDatabase.open(path: databasePath)
    try database.execute("""
      CREATE TABLE workflow_runtime_snapshots(workflow_execution_id TEXT PRIMARY KEY,workflow_id TEXT,session_status TEXT,
        parent_session_id TEXT,root_session_id TEXT,updated_at TEXT,session_json BLOB,root_output_json BLOB,
        diagnostics_json BLOB,loop_evidence_json BLOB,loop_summary_json BLOB)
      """)
    try database.execute("CREATE TABLE workflow_messages(workflow_execution_id TEXT,payload_json BLOB,artifact_refs_json BLOB)")
    return database
  }

  private func insertSession(_ id: String, database: SQLiteDatabase) throws {
    let date = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_000))
    try database.execute("""
      INSERT INTO workflow_runtime_snapshots VALUES(?, 'sample', 'completed', NULL, ?, ?, jsonb('{}'),
        jsonb('{"body":"old result"}'), jsonb('[]'), NULL, NULL)
      """, bindings: [.text(id), .text(id), .text(date)])
    try database.execute("""
      INSERT INTO workflow_messages VALUES(?, jsonb('{"body":"message"}'), jsonb('[]'))
      """,
      bindings: [.text(id)])
  }

  private final class FreeSpaceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    var count: Int {
      lock.lock()
      defer { lock.unlock() }
      return paths.count
    }

    func record(_ path: String) {
      lock.lock()
      paths.append(path)
      lock.unlock()
    }
  }

  private func makeRoot() throws -> URL {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/riela-retention-service-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    roots.append(root)
    return root
  }
}
