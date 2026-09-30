import Foundation
import XCTest
@testable import RielaCore

final class RielaDataGarbageCollectorHandoverTests: XCTestCase {
  private var roots: [URL] = []

  override func tearDown() {
    for root in roots.reversed() {
      try? FileManager.default.removeItem(at: root)
    }
    roots = []
    super.tearDown()
  }

  func testHandoverFilesRemoveTerminalAndAbsentTasksAndDryRunReportsEveryDecision() throws {
    let home = try makeRoot()
    try runGit(["init", "-q"], in: home)
    try assertTopLevelInsideFixture(home)
    let storeRoot = home.appendingPathComponent(".riela", isDirectory: true)
    try seedTasks([("task-done", "succeeded"), ("task-active", "waiting")], storeRoot: storeRoot)
    let handovers = storeRoot.appendingPathComponent("sessions/handovers", isDirectory: true)
    let terminal = handovers.appendingPathComponent("task-done", isDirectory: true)
    let active = handovers.appendingPathComponent("task-active", isDirectory: true)
    let absent = handovers.appendingPathComponent("task-absent", isDirectory: true)
    let runtimeHandovers = storeRoot.appendingPathComponent("sessions/runtime-records/handovers", isDirectory: true)
    let runtimeTerminal = runtimeHandovers.appendingPathComponent("task-done", isDirectory: true)
    let runtimeActive = runtimeHandovers.appendingPathComponent("task-active", isDirectory: true)
    for directory in [terminal, active, absent, runtimeTerminal, runtimeActive] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data("packet".utf8).write(to: directory.appendingPathComponent("handover.json"))
    }

    let collector = RielaDataGarbageCollector()
    let dryRun = collector.collect(
      retentionDays: 7,
      scope: .user,
      homeDirectory: home,
      projectDirectory: home,
      dryRun: true
    )

    XCTAssertTrue(FileManager.default.fileExists(atPath: terminal.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: absent.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: runtimeTerminal.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: runtimeActive.path))
    XCTAssertEqual(decisions(in: dryRun.handoverFiles), [
      terminal.path: .wouldRemove,
      active.path: .kept,
      absent.path: .wouldRemove,
      runtimeTerminal.path: .wouldRemove,
      runtimeActive.path: .kept
    ])
    XCTAssertEqual(dryRun.handoverRefs, [])

    let report = collector.collect(
      retentionDays: 7,
      scope: .user,
      homeDirectory: home,
      projectDirectory: home
    )

    XCTAssertFalse(FileManager.default.fileExists(atPath: terminal.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: runtimeTerminal.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: runtimeActive.path))
    XCTAssertEqual(decisions(in: report.handoverFiles), [
      terminal.path: .removed,
      active.path: .kept,
      absent.path: .removed,
      runtimeTerminal.path: .removed,
      runtimeActive.path: .kept
    ])
    XCTAssertEqual(report.handoverRefs, [])
  }

  func testHandoverRefsDeleteOnlyTerminalTasksWithoutUsingRemote() throws {
    let repository = try makeRoot()
    try runGit(["init", "-q"], in: repository)
    try assertTopLevelInsideFixture(repository)
    try runGit(["-c", "user.name=GC Tests", "-c", "user.email=gc@example.invalid", "commit", "--allow-empty", "-m", "fixture"], in: repository)
    let storeRoot = repository.appendingPathComponent(".riela", isDirectory: true)
    try seedTasks([("task-done", "succeeded"), ("task-active", "waiting")], storeRoot: storeRoot)
    try runGit(["update-ref", "refs/riela/handovers/task-done/handover-1", "HEAD"], in: repository)
    try runGit(["update-ref", "refs/riela/handovers/task-active/handover-2", "HEAD"], in: repository)

    let dryRun = RielaDataGarbageCollector().collect(
      retentionDays: 7,
      scope: .project,
      homeDirectory: repository,
      projectDirectory: repository,
      dryRun: true
    )
    XCTAssertEqual(decisions(in: dryRun.handoverRefs), [
      "refs/riela/handovers/task-done/handover-1": .wouldRemove,
      "refs/riela/handovers/task-active/handover-2": .kept
    ])
    XCTAssertEqual(try localHandoverRefs(in: repository), [
      "refs/riela/handovers/task-active/handover-2",
      "refs/riela/handovers/task-done/handover-1"
    ])

    let report = RielaDataGarbageCollector().collect(
      retentionDays: 7,
      scope: .project,
      homeDirectory: repository,
      projectDirectory: repository
    )

    XCTAssertEqual(decisions(in: report.handoverRefs), [
      "refs/riela/handovers/task-done/handover-1": .removed,
      "refs/riela/handovers/task-active/handover-2": .kept
    ])
    XCTAssertEqual(try localHandoverRefs(in: repository), ["refs/riela/handovers/task-active/handover-2"])
    XCTAssertEqual(try runGit(["remote"], in: repository).trimmingCharacters(in: .whitespacesAndNewlines), "")
  }

  func testMissingTaskDatabaseLeavesHandoverFilesUntouchedAndReportsDiagnostic() throws {
    let home = try makeRoot()
    try runGit(["init", "-q"], in: home)
    try assertTopLevelInsideFixture(home)
    let handoverDirectory = home.appendingPathComponent(".riela/sessions/handovers/task-unknown", isDirectory: true)
    try FileManager.default.createDirectory(at: handoverDirectory, withIntermediateDirectories: true)
    try Data("packet".utf8).write(to: handoverDirectory.appendingPathComponent("handover.json"))

    let report = RielaDataGarbageCollector().collect(
      retentionDays: 7,
      scope: .user,
      homeDirectory: home,
      projectDirectory: home
    )

    XCTAssertTrue(FileManager.default.fileExists(atPath: handoverDirectory.path))
    XCTAssertTrue(report.diagnostics.contains { $0.contains("task database is missing") })
    XCTAssertEqual(decisions(in: report.handoverFiles), [handoverDirectory.path: .skipped])
    XCTAssertEqual(report.handoverRefs, [])
  }

  private func makeRoot() throws -> URL {
    let unresolvedRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-gc-handover-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: unresolvedRoot, withIntermediateDirectories: true)
    let root = hermeticRealPath(unresolvedRoot)
    roots.append(root)
    return root
  }

  private func seedTasks(_ tasks: [(String, String)], storeRoot: URL) throws {
    let database = storeRoot.appendingPathComponent(
      "sessions/runtime-records/runtime-message-log.sqlite",
      isDirectory: false
    )
    try FileManager.default.createDirectory(
      at: database.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let rows = tasks.map { (taskId, state) in
      "INSERT INTO work_tasks (task_id, state) VALUES ('\(taskId)', '\(state)');"
    }.joined(separator: "\n")
    try runSQLite(
      database: database,
      sql: "CREATE TABLE work_tasks (task_id TEXT PRIMARY KEY, state TEXT NOT NULL);\n\(rows)"
    )
  }

  private func runSQLite(database: URL, sql: String) throws {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["sqlite3", database.path]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = output
    try process.run()
    input.fileHandleForWriting.write(Data(sql.utf8))
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    let text = String(bytes: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
      throw NSError(domain: "RielaDataGarbageCollectorHandoverTests", code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: text])
    }
  }

  private func decisions(
    in entries: [RielaGarbageCollectionItem]
  ) -> [String: RielaGarbageCollectionDecision] {
    Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0.decision) })
  }

  private func localHandoverRefs(in repository: URL) throws -> [String] {
    try runGit(["for-each-ref", "--format=%(refname)", "refs/riela/handovers/"], in: repository)
      .split(whereSeparator: \.isNewline)
      .map(String.init)
  }

  @discardableResult
  private func runGit(_ arguments: [String], in directory: URL) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.currentDirectoryURL = directory
    process.environment = hermeticGitEnvironment()
    process.standardOutput = output
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    let text = String(bytes: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
      throw NSError(domain: "RielaDataGarbageCollectorHandoverTests", code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: text])
    }
    return text
  }

  private func hermeticGitEnvironment() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_COMMON_DIR"] {
      environment.removeValue(forKey: key)
    }
    environment["GIT_CEILING_DIRECTORIES"] = hermeticRealPath(FileManager.default.temporaryDirectory).path
    environment["GIT_TERMINAL_PROMPT"] = "0"
    return environment
  }

  private func assertTopLevelInsideFixture(_ repository: URL) throws {
    let output = try runGit(["rev-parse", "--show-toplevel"], in: repository)
    let topLevel = hermeticRealPath(URL(fileURLWithPath: output.trimmingCharacters(in: .whitespacesAndNewlines))).path
    let fixturePrefix = hermeticRealPath(repository).path + "/"
    XCTAssertTrue(
      topLevel + "/" == fixturePrefix || topLevel.hasPrefix(fixturePrefix),
      "fixture repository top level \(topLevel) escaped \(fixturePrefix)"
    )
  }
}

private func hermeticRealPath(_ url: URL) -> URL {
  var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
  guard realpath(url.path, &buffer) != nil else { return url.standardizedFileURL }
  return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
}
