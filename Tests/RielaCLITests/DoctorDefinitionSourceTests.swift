import CryptoKit
import Foundation
import RielaCore
import RielaSQLite
import RielaWorkflowRegistry
import XCTest
@testable import RielaCLI

final class DoctorDefinitionSourceTests: XCTestCase {
  func testDefinitionSourcesAndReadOnlyTextReport() async throws {
    let fixture = try makeFixture()
    for name in ["in-sync", "pending", "edited", "broken"] {
      try fixture.seed(name)
    }
    _ = try fixture.service.updatePrompt(
      workflowName: "edited", nodeId: "worker", field: .init(parsing: "promptTemplate"),
      text: "manual edit", reason: "test", expectedVersionId: nil, evidence: [], actor: .init(kind: .user)
    )
    try fixture.edit("pending")
    try fixture.edit("edited")
    try "{".write(to: fixture.workflowFile("broken"), atomically: true, encoding: .utf8)
    let before = try fixture.rowCounts()
    let json = await fixture.doctor(output: "json")
    XCTAssertEqual(json.exitCode, .success, json.stderr)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let report = try decoder.decode(DoctorCommandResult.self, from: Data(json.stdout.utf8))
    let rows = Dictionary(uniqueKeysWithValues: report.definitionSources.compactMap { row in
      row.workflowName.map { ($0, row) }
    })
    XCTAssertEqual(rows.count, 4)
    XCTAssertEqual(rows["in-sync"]?.result, "inSync")
    XCTAssertEqual(rows["in-sync"]?.status, .ok)
    XCTAssertEqual(rows["pending"]?.result, "pendingAutoSync")
    XCTAssertEqual(rows["pending"]?.status, .warning)
    XCTAssertEqual(rows["edited"]?.result, "drift")
    XCTAssertEqual(rows["edited"]?.status, .warning)
    XCTAssertEqual(rows["broken"]?.result, "sourceInvalid")
    XCTAssertEqual(rows["broken"]?.status, .warning)
    XCTAssertEqual(report.summary.definitionSourceWarnings, 3)
    XCTAssertEqual(report.summary.status, .warning)
    let message = try XCTUnwrap(rows["edited"]?.message)
    for fragment in ["riela instance reload", "import", "--force"] {
      XCTAssertTrue(message.contains(fragment), message)
    }
    let text = await fixture.doctor(output: "text")
    XCTAssertEqual(text.exitCode, .success, text.stderr)
    XCTAssertTrue(text.stdout.contains("Definition sources:"), text.stdout)
    XCTAssertTrue(text.stdout.contains("drift"), text.stdout)
    XCTAssertEqual(try fixture.rowCounts(), before)
  }

  func testMissingStoreIsNotCreated() async throws {
    let fixture = try makeFixture()
    let result = await fixture.doctor(output: "json")
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let report = try decoder.decode(DoctorCommandResult.self, from: Data(result.stdout.utf8))
    XCTAssertTrue(report.definitionSources.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.databasePath))
  }

  func testMismatchedGenerationIsNotModified() async throws {
    let fixture = try makeFixture()
    try fixture.seed("in-sync")
    let source = fixture.databasePath
    do {
      let db = try SQLiteDatabase.open(path: source, mode: .readWriteCreate, options: .readOnlyDefault)
      _ = try db.query("PRAGMA wal_checkpoint(TRUNCATE)")
    }
    let copyRoot = fixture.root.appendingPathComponent("copy")
    try FileManager.default.createDirectory(at: copyRoot, withIntermediateDirectories: true)
    let copyPath = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: copyRoot.path)
    try FileManager.default.copyItem(atPath: source, toPath: copyPath)
    do {
      let db = try SQLiteDatabase.open(path: copyPath, mode: .readWriteCreate, options: .readOnlyDefault)
      try db.execute("PRAGMA user_version = 9999")
      _ = try db.query("PRAGMA wal_checkpoint(TRUNCATE)")
    }
    let before = try Data(contentsOf: URL(fileURLWithPath: copyPath))
    let result = await fixture.doctor(output: "json", store: copyRoot.path)
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let report = try decoder.decode(DoctorCommandResult.self, from: Data(result.stdout.utf8))
    XCTAssertEqual(report.definitionSources.count, 1)
    XCTAssertEqual(report.definitionSources.first?.result, "storeUnreadable")
    XCTAssertEqual(report.definitionSources.first?.status, .unknown)
    let after = try Data(contentsOf: URL(fileURLWithPath: copyPath))
    XCTAssertEqual(after.count, before.count)
    XCTAssertEqual(SHA256.hash(data: after), SHA256.hash(data: before))
    XCTAssertEqual(after, before)
  }

  private func makeFixture() throws -> DoctorSourceFixture {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(
      "tmp/stale-definition/sdwd-04-doctor-drift-report/fixture-\(UUID().uuidString)"
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return DoctorSourceFixture(root: root)
  }
}

private struct DoctorSourceFixture {
  let root: URL
  var store: URL { root.appendingPathComponent("store") }
  var databasePath: String { SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: store.path) }
  var service: WorkflowDefinitionService {
    WorkflowDefinitionService(storeRoot: store.path, fileResolver: FileSystemWorkflowBundleResolver())
  }
  func workflowFile(_ name: String) -> URL { root.appendingPathComponent("\(name)/workflow.json") }
  func seed(_ name: String) throws {
    let workflow = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: workflow.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    try """
    {"workflowId":"\(name)","entryStepId":"work","defaults":{"nodeTimeoutMs":3300000,"maxLoopIterations":1},
    "nodes":[{"id":"worker","nodeFile":"nodes/worker.json"}],"steps":[{"id":"work","nodeId":"worker","role":"worker"}]}
    """.write(to: workflowFile(name), atomically: true, encoding: .utf8)
    try #"{"id":"worker","executionBackend":"codex-agent","agentSandbox":"read-only","model":"test-model","modelFreeze":false,"promptTemplate":"original","output":{"description":"Return a result."}}"#
      .write(to: workflow.appendingPathComponent("nodes/worker.json"), atomically: true, encoding: .utf8)
    let options = WorkflowResolutionOptions(workflowName: name, workflowDefinitionDir: workflow.path, workingDirectory: root.path)
    let bundle = try FileSystemWorkflowBundleResolver().resolve(options)
    _ = try service.seedIfAbsent(fileBundle: bundle, workflowName: name, actor: .init(kind: .api, id: "test"))
  }
  func edit(_ name: String) throws {
    let file = workflowFile(name)
    let contents = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "3300000", with: "21600000")
    try contents.write(to: file, atomically: true, encoding: .utf8)
  }
  func rowCounts() throws -> [Int] {
    let db = try SQLiteDatabase.open(path: databasePath, mode: .strictReadOnly, options: .readOnlyDefault)
    return try ["definition_history_versions", "definition_versions", "definition_heads", "definition_change_audit"].map {
      Int(try XCTUnwrap(db.query("SELECT COUNT(*) AS count FROM \($0)").first?["count"])) ?? -1
    }
  }
  func doctor(output: String, store: String? = nil) async -> CLICommandResult {
    await RielaCLIApplication().run([
      "doctor", "--scope", "project", "--working-dir", root.path,
      "--session-store", store ?? self.store.path, "--output", output
    ], environment: ["PATH": "", "HOME": root.path, "RIELA_WORKFLOW_HOME": root.appendingPathComponent("home").path])
  }
}
