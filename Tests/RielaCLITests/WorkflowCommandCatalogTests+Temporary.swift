import Foundation
import XCTest
@testable import RielaCLI

extension WorkflowCommandCatalogTests {
  func testListQueryMatchesPackageNameDirectly() {
    let entry = WorkflowCatalogEntry(
      workflowName: "unrelated-workflow",
      scope: .user,
      sourceKind: .package,
      workflowDirectory: "/tmp/unrelated-workflow",
      packageName: "Package-Only-Needle",
      mutable: false,
      valid: true,
      diagnostics: []
    )

    XCTAssertTrue(WorkflowCatalogCommand.matchesQuery(entry, query: "package-only"))
    XCTAssertFalse(WorkflowCatalogCommand.matchesQuery(entry, query: "missing"))
  }

  func testTemporaryCatalogDirectProvenanceInvalidExclusionAndQueryMatrix() async throws {
    let layout = try makeCatalogMatrixLayout()
    defer { try? FileManager.default.removeItem(at: layout.base) }
    let workflowId = "shared-catalog"
    let standard = layout.home
      .appendingPathComponent(".riela/workflows", isDirectory: true)
      .appendingPathComponent(workflowId, isDirectory: true)
    try writeCatalogMatrixBundle(
      at: standard,
      workflowId: workflowId,
      description: "description-only-token"
    )
    let input = layout.inputs.appendingPathComponent(workflowId, isDirectory: true)
    try writeCatalogMatrixBundle(
      at: input,
      workflowId: workflowId,
      description: "description-only-token"
    )
    let environment = ["HOME": layout.home.path]
    let application = RielaCLIApplication()
    let registration = await application.run([
      "workflow", "register", input.path, "--temporary", "--output", "json"
    ], environment: environment)
    XCTAssertEqual(registration.exitCode, .success, registration.stderr + registration.stdout)

    let invalid = layout.home
      .appendingPathComponent(".riela/temporary-workflows/invalid-temporary", isDirectory: true)
    try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
    try #"{"workflowId":"invalid-temporary""#
      .write(to: invalid.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)

    let all = await application.run([
      "workflow", "list", "--scope", "user", "--output", "json"
    ], environment: environment)
    XCTAssertEqual(all.exitCode, .success, all.stderr + all.stdout)
    let allEntries = try decodeCatalogMatrix(all.stdout).workflows
    let duplicates = allEntries.filter { $0.workflowName == workflowId }
    XCTAssertEqual(duplicates.count, 2)
    XCTAssertEqual(duplicates.filter { $0.provenance == .mutable }.count, 1)
    XCTAssertTrue(duplicates.contains {
      $0.provenance == .mutable && $0.workflowDirectory.contains("temporary-workflows/\(workflowId)")
    })
    let invalidEntry = try XCTUnwrap(allEntries.first { $0.workflowName == "invalid-temporary" })
    XCTAssertEqual(invalidEntry.provenance, .mutable)
    XCTAssertFalse(invalidEntry.valid)
    XCTAssertFalse(allEntries.contains { $0.workflowName == WorkflowMutableRegistry.reservedStateName })

    let caseInsensitive = await application.run([
      "workflow", "list", "SHARED-CATALOG", "--scope", "user", "--output", "json"
    ], environment: environment)
    XCTAssertEqual(try decodeCatalogMatrix(caseInsensitive.stdout).workflows.count, 2)

    let descriptionMatch = await application.run([
      "workflow", "list", "description-only-token", "--scope", "user", "--output", "json"
    ], environment: environment)
    XCTAssertEqual(try decodeCatalogMatrix(descriptionMatch.stdout).workflows.count, 2)

    let pathDoesNotMatch = await application.run([
      "workflow", "list", "temporary-workflows", "--scope", "user", "--output", "json"
    ], environment: environment)
    XCTAssertEqual(try decodeCatalogMatrix(pathDoesNotMatch.stdout).workflows, [])

    let excludedInvalid = await application.run([
      "workflow", "list", "invalid-temporary", "--scope", "user",
      "--exclude-temporary", "--output", "json"
    ], environment: environment)
    XCTAssertEqual(try decodeCatalogMatrix(excludedInvalid.stdout).workflows, [])
  }

  func testTemporaryCatalogPersistsAcrossSeparateCLIProcess() async throws {
    let layout = try makeCatalogMatrixLayout()
    defer { try? FileManager.default.removeItem(at: layout.base) }
    let input = layout.inputs.appendingPathComponent("process-persisted", isDirectory: true)
    try writeCatalogMatrixBundle(
      at: input,
      workflowId: "process-persisted",
      description: "separate process"
    )
    let environment = ["HOME": layout.home.path]
    let registration = await RielaCLIApplication().run([
      "workflow", "register", input.path, "--temporary", "--output", "json"
    ], environment: environment)
    XCTAssertEqual(registration.exitCode, .success, registration.stderr + registration.stdout)

    let executable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent(".build/debug/riela")
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path), executable.path)
    let process = Process()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = executable
    process.arguments = [
      "workflow", "list", "process-persisted", "--scope", "user", "--output", "json"
    ]
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, override in override }
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    process.waitUntilExit()
    let stdout = String(
      data: output.fileHandleForReading.readDataToEndOfFile(),
      encoding: .utf8
    ) ?? ""
    let stderr = String(
      data: errors.fileHandleForReading.readDataToEndOfFile(),
      encoding: .utf8
    ) ?? ""
    XCTAssertEqual(process.terminationStatus, 0, stderr + stdout)
    let entry = try XCTUnwrap(decodeCatalogMatrix(stdout).workflows.first)
    XCTAssertEqual(entry.workflowName, "process-persisted")
    XCTAssertEqual(entry.provenance, .mutable)
  }
}

private struct CatalogMatrixLayout {
  var base: URL
  var home: URL
  var inputs: URL
}

private func makeCatalogMatrixLayout() throws -> CatalogMatrixLayout {
  let base = FileManager.default.temporaryDirectory
    .appendingPathComponent("riela-catalog-matrix-\(UUID().uuidString)", isDirectory: true)
  let layout = CatalogMatrixLayout(
    base: base,
    home: base.appendingPathComponent("home", isDirectory: true),
    inputs: base.appendingPathComponent("inputs", isDirectory: true)
  )
  try FileManager.default.createDirectory(at: layout.home, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: layout.inputs, withIntermediateDirectories: true)
  return layout
}

private func writeCatalogMatrixBundle(
  at directory: URL,
  workflowId: String,
  description: String
) throws {
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  try """
  {
    "workflowId": "\(workflowId)",
    "description": "\(description)",
    "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
    "entryStepId": "work",
    "nodes": [{ "id": "worker", "addon": { "name": "example-addon" } }],
    "steps": [{ "id": "work", "nodeId": "worker", "role": "worker" }]
  }
  """.write(to: directory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
}

private func decodeCatalogMatrix(_ output: String) throws -> WorkflowCatalogResult {
  try JSONDecoder().decode(WorkflowCatalogResult.self, from: Data(output.utf8))
}
