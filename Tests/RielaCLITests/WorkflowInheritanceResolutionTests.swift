import Foundation
import RielaAddons
import XCTest
@testable import RielaCLI
import RielaCore
import RielaWorkflowRegistry

final class WorkflowInheritanceResolutionTests: XCTestCase {
  func testInstalledUserPackageValidateInspectAndRun() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.writeInstalledPackages()
    try fixture.writeOrdinary(id: "wrong-base", directoryName: "base")
    let originalPackageContents = try fixture.packageContents()
    let app = RielaCLIApplication()

    try await CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.home.path]) {
      let validate = await app.run([
        "workflow", "validate", "derived-package", "--scope", "user",
        "--working-dir", fixture.root.path, "--output", "json"
      ])
      XCTAssertEqual(validate.exitCode, .success, validate.stderr + validate.stdout)
      let validation = try decode(WorkflowValidationCommandResult.self, from: validate.stdout)
      XCTAssertTrue(validation.valid)
      XCTAssertEqual(validation.workflowId, "derived")
      XCTAssertEqual(validation.sourceKind, .package)
      XCTAssertEqual(validation.packageName, "derived-package")

      let inspect = await app.run([
        "workflow", "inspect", "derived-package", "--scope", "user",
        "--working-dir", fixture.root.path,
        "--output", "json"
      ])
      XCTAssertEqual(inspect.exitCode, .success, inspect.stderr + inspect.stdout)
      let summary = try decode(WorkflowInspectionSummary.self, from: inspect.stdout)
      XCTAssertEqual(summary.workflowId, "derived")
      XCTAssertEqual(summary.entryStepId, "worker")
      XCTAssertEqual(summary.stepIds, ["worker"])
      XCTAssertEqual(summary.sourceKind, .package)
      XCTAssertEqual(summary.packageName, "derived-package")
      XCTAssertTrue(summary.runtimeReadinessDescriptors.contains("worker:claude-code-agent"))

      let patchedValidate = await app.run([
        "workflow", "validate", "derived-package", "--scope", "user",
        "--working-dir", fixture.root.path,
        "--node-patch", #"{"worker":{"executionBackend":"cursor-cli-agent","model":"caller-model"}}"#,
        "--output", "json"
      ])
      XCTAssertEqual(patchedValidate.exitCode, .success, patchedValidate.stderr + patchedValidate.stdout)

      let run = await app.run([
        "workflow", "run", "derived-package", "--scope", "user",
        "--working-dir", fixture.root.path,
        "--mock-scenario", fixture.scenario.path,
        "--session-store", fixture.sessions.path,
        "--output", "json"
      ])
      XCTAssertEqual(run.exitCode, .success, run.stderr + run.stdout)
      let result = try decode(WorkflowRunResult.self, from: run.stdout)
      XCTAssertEqual(result.workflowId, "derived")
      XCTAssertEqual(result.status, .completed)
      XCTAssertEqual(result.nodeExecutions, 1)
      XCTAssertEqual(result.transitions, 0)
      XCTAssertEqual(result.rootOutput?["status"], .string("ready"))
      XCTAssertEqual(result.rootOutput?["marker"], .string("issue-94-inheritance"))
    }

    XCTAssertEqual(try fixture.packageContents(), originalPackageContents)
  }

  func testSparseUserWorkflowResolvesBaseAndPreservesOrdinaryControl() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.writeOrdinary(id: "base")
    try fixture.writeDerived(id: "derived", base: "base")

    try CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.home.path]) {
      let resolver = FileSystemWorkflowBundleResolver(enforcesTransactionBlock: false)
      let derived = try resolver.resolve(WorkflowResolutionOptions(
        workflowName: "derived", scope: .user, workingDirectory: fixture.root.path
      ))
      XCTAssertEqual(derived.workflow.workflowId, "derived")
      XCTAssertEqual(derived.workflow.entryStepId, "worker")
      XCTAssertEqual(derived.nodePayloads["worker"]?.executionBackend, .claudeCodeAgent)
      XCTAssertEqual(derived.nodePayloads["worker"]?.model, "opus")
      let ordinary = try resolver.resolve(WorkflowResolutionOptions(
        workflowName: "base", scope: .user, workingDirectory: fixture.root.path
      ))
      XCTAssertEqual(ordinary.workflow.workflowId, "base")
      XCTAssertEqual(ordinary.nodePayloads["worker"]?.model, "gpt-5")
    }
  }

  func testMissingBaseAndDirectCycleFail() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.writeDerived(id: "missing", base: "absent")
    try fixture.writeDerived(id: "cycle", base: "cycle")
    try CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.home.path]) {
      let resolver = FileSystemWorkflowBundleResolver(enforcesTransactionBlock: false)
      XCTAssertThrowsError(try resolver.resolve(WorkflowResolutionOptions(
        workflowName: "missing", scope: .user, workingDirectory: fixture.root.path
      ))) { error in
        let message = workflowResolutionErrorDescription(error)
        XCTAssertTrue(message.contains("extends missing base 'absent'"), message)
        XCTAssertTrue(message.contains("install it for user scope"), message)
        XCTAssertTrue(message.contains("--scope user"), message)
      }
      XCTAssertThrowsError(try resolver.resolve(WorkflowResolutionOptions(
        workflowName: "cycle", scope: .user, workingDirectory: fixture.root.path
      )))
    }
  }

  func testIndirectCycleAndRepeatedIndependentBaseLoads() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.writeOrdinary(id: "base")
    try fixture.writeDerived(id: "first", base: "base")
    try fixture.writeDerived(id: "second", base: "base")
    try fixture.writeDerived(id: "cycle-a", base: "cycle-b")
    try fixture.writeDerived(id: "cycle-b", base: "cycle-a")

    try CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.home.path]) {
      let resolver = FileSystemWorkflowBundleResolver(enforcesTransactionBlock: false)
      XCTAssertEqual(try resolver.resolve(options(for: "first", fixture: fixture)).workflow.workflowId, "first")
      XCTAssertEqual(try resolver.resolve(options(for: "second", fixture: fixture)).workflow.workflowId, "second")
      XCTAssertThrowsError(try resolver.resolve(options(for: "cycle-a", fixture: fixture))) { error in
        guard case let WorkflowInheritanceError.cycle(chain) = error else {
          return XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(chain, ["cycle-a", "cycle-b", "cycle-a"])
      }
    }
  }

  func testMismatchedDirectoryNameCannotBecomeInheritanceBase() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.writeOrdinary(id: "wrong-base", directoryName: "base")
    try fixture.writeDerived(id: "derived", base: "base")

    try CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.home.path]) {
      let resolver = FileSystemWorkflowBundleResolver(enforcesTransactionBlock: false)
      XCTAssertThrowsError(try resolver.resolve(options(for: "derived", fixture: fixture))) { error in
        guard case let WorkflowInheritanceError.missingBase(_, baseWorkflowId, _) = error else {
          return XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(baseWorkflowId, "base")
      }
    }
  }

  private func options(for workflowName: String, fixture: Fixture) -> WorkflowResolutionOptions {
    WorkflowResolutionOptions(
      workflowName: workflowName,
      scope: .user,
      workingDirectory: fixture.root.path
    )
  }

  private func decode<T: Decodable>(_ type: T.Type, from output: String) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(T.self, from: Data(output.utf8))
  }
}

private struct Fixture {
  let root: URL
  let home: URL
  let workflows: URL
  let packages: URL
  let scenario: URL
  let sessions: URL

  init() throws {
    root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/issue-94-implementation/fixtures/\(UUID().uuidString)")
    home = root.appendingPathComponent("home")
    workflows = home.appendingPathComponent(".riela/workflows")
    packages = home.appendingPathComponent(".riela/packages")
    scenario = root.appendingPathComponent("mock-scenario.json")
    sessions = root.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: workflows, withIntermediateDirectories: true)
  }

  func writeInstalledPackages() throws {
    let basePackage = packages.appendingPathComponent("base-package")
    let baseWorkflow = basePackage.appendingPathComponent("workflows/base")
    try writeOrdinary(id: "base", at: baseWorkflow)
    let baseChecksum = try WorkflowPackageChecksum.md5(packageRoot: basePackage)
    try writeManifest(
      name: "base-package", checksum: baseChecksum, workflowDirectory: "workflows/base",
      dependencies: [], to: basePackage
    )

    let derivedPackage = packages.appendingPathComponent("derived-package")
    let derivedWorkflow = derivedPackage.appendingPathComponent("workflows/derived")
    try writeDerived(id: "derived", base: "base", at: derivedWorkflow)
    let derivedChecksum = try WorkflowPackageChecksum.md5(packageRoot: derivedPackage)
    try writeManifest(
      name: "derived-package", checksum: derivedChecksum, workflowDirectory: "workflows/derived",
      dependencies: ["base-package"], to: derivedPackage
    )
    try Data(#"{"worker":{"provider":"scenario-mock","model":"mock","when":{"always":true},"payload":{"status":"ready","marker":"issue-94-inheritance"}}}"#.utf8)
      .write(to: scenario)
  }

  func writeOrdinary(id: String) throws {
    try writeOrdinary(id: id, directoryName: id)
  }

  func writeOrdinary(id: String, directoryName: String) throws {
    let directory = workflows.appendingPathComponent(directoryName)
    try writeOrdinary(id: id, at: directory)
  }

  private func writeOrdinary(id: String, at directory: URL) throws {
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    let workflowJSON = #"""
    {
      "workflowId":"\#(id)",
      "defaults":{"nodeTimeoutMs":1000,"maxLoopIterations":2},
      "entryStepId":"worker",
      "nodes":[{"id":"worker","nodeFile":"nodes/worker.json"}],
      "steps":[{"id":"worker","nodeId":"worker"}]
    }
    """#
    try Data(workflowJSON.utf8)
      .write(to: directory.appendingPathComponent("workflow.json"))
    try Data(#"{"id":"worker","nodeType":"agent","executionBackend":"codex-agent","model":"gpt-5","modelFreeze":false,"promptTemplate":"ready"}"#.utf8)
      .write(to: directory.appendingPathComponent("nodes/worker.json"))
  }

  func writeDerived(id: String, base: String) throws {
    let directory = workflows.appendingPathComponent(id)
    try writeDerived(id: id, base: base, at: directory)
  }

  private func writeDerived(id: String, base: String, at directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let json = """
    {"workflowId":"\(id)","extends":{"workflowId":"\(base)","agentNodePatch":{"executionBackend":"claude-code-agent","model":"sonnet"},"nodePatch":{"worker":{"model":"opus"}}}}
    """
    try Data(json.utf8).write(to: directory.appendingPathComponent("workflow.json"))
  }

  private func writeManifest(
    name: String,
    checksum: String,
    workflowDirectory: String,
    dependencies: [String],
    to directory: URL
  ) throws {
    let dependencyJSON = dependencies.map { #""\#($0)""# }.joined(separator: ",")
    let json = """
    {
      "name":"\(name)",
      "version":"1.0.0",
      "description":"Issue 94 installed inheritance fixture",
      "tags":["workflow"],
      "dependencies":[\(dependencyJSON)],
      "registry":"fixture",
      "checksum":"\(checksum)",
      "checksumAlgorithm":"md5",
      "workflowDirectory":"\(workflowDirectory)"
    }
    """
    try Data(json.utf8).write(to: directory.appendingPathComponent("riela-package.json"))
  }

  func packageContents() throws -> [String: Data] {
    guard let enumerator = FileManager.default.enumerator(
      at: packages,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else { return [:] }
    var result: [String: Data] = [:]
    for case let file as URL in enumerator {
      guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
      let relativePath = String(file.path.dropFirst(packages.path.count + 1))
      result[relativePath] = try Data(contentsOf: file)
    }
    return result
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
