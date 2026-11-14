import Foundation
import RielaAddons
import RielaCore
import XCTest
@testable import RielaCLI

/// Records executed commands and returns scripted results so publish git
/// transport can be exercised offline.
final class FakeWorkflowPackageCommandExecutor: WorkflowPackageCommandExecutor, @unchecked Sendable {
  struct Invocation: Equatable {
    var executable: String
    var arguments: [String]
  }

  private let lock = NSLock()
  private(set) var invocations: [Invocation] = []
  var remoteURL = "https://github.com/acme/packages"
  var dirtyStatus = ""
  var canPush = true
  var handler: (@Sendable ([String]) -> WorkflowPackageGitCommandResult?)?

  func run(_ executable: String, arguments: [String], workingDirectory: URL?) throws -> WorkflowPackageGitCommandResult {
    lock.lock()
    invocations.append(Invocation(executable: executable, arguments: arguments))
    lock.unlock()
    if let handler, let scripted = handler(arguments) {
      return scripted
    }
    return defaultResult(for: arguments)
  }

  func invocationArguments() -> [[String]] {
    lock.lock()
    defer { lock.unlock() }
    return invocations.map(\.arguments)
  }

  private func defaultResult(for arguments: [String]) -> WorkflowPackageGitCommandResult {
    func ok(_ out: String = "") -> WorkflowPackageGitCommandResult {
      WorkflowPackageGitCommandResult(exitCode: 0, standardOutput: out, standardError: "")
    }
    func fail(_ err: String) -> WorkflowPackageGitCommandResult {
      WorkflowPackageGitCommandResult(exitCode: 1, standardOutput: "", standardError: err)
    }
    switch arguments.first {
    case "remote":
      return ok(remoteURL)
    case "status":
      return ok(dirtyStatus)
    case "push":
      if arguments.contains("--dry-run") {
        return canPush ? ok() : fail("permission denied")
      }
      return ok()
    case "rev-parse":
      if arguments.contains("HEAD") {
        return ok("abc123def456")
      }
      return fail("unknown revision")
    default:
      return ok()
    }
  }
}

final class FakeWorkflowPackagePullRequestAdapter: WorkflowPackagePullRequestAdapter, @unchecked Sendable {
  var result: Result<String, Error> = .success("https://github.com/acme/packages/pull/7")
  private(set) var lastRequest: WorkflowPackagePullRequestRequest?

  func createPullRequest(_ request: WorkflowPackagePullRequestRequest) throws -> String {
    lastRequest = request
    return try result.get()
  }
}

final class WorkflowPackagePublishGitTests: XCTestCase {
  private func makeWorkflowSource(at directory: URL) throws {
    let root = FileManager.default.currentDirectoryPath
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/workflow.json"),
      to: directory.appendingPathComponent("workflow.json")
    )
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/nodes"),
      to: directory.appendingPathComponent("nodes")
    )
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/prompts"),
      to: directory.appendingPathComponent("prompts")
    )
  }

  private func makeGitCheckout(at directory: URL) throws {
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent(".git"),
      withIntermediateDirectories: true
    )
  }

  private func publishOptions(
    source: URL,
    workingDirectory: URL,
    registryLocalPath: URL,
    extra: [String]
  ) -> CLICommandOptions {
    CLICommandOptions(
      scope: "project",
      command: "publish",
      target: source.path,
      arguments: [
        "--package-id", "demo-package",
        "--registry", "https://github.com/acme/packages",
        "--registry-local-path", registryLocalPath.path,
        "--working-dir", workingDirectory.path,
        "--yes",
        "--output", "json"
      ] + extra,
      output: .json
    )
  }

  private func tempRoot(_ label: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("riela-publish-git-\(label)-\(UUID().uuidString)", isDirectory: true)
  }

  func testPublishComputesRealChecksumAndBackendHints() async throws {
    let tempDir = tempRoot("checksum")
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let source = tempDir.appendingPathComponent("source", isDirectory: true)
    try makeWorkflowSource(at: source)
    let registryLocal = tempDir.appendingPathComponent("registry", isDirectory: true)
    try FileManager.default.createDirectory(at: registryLocal, withIntermediateDirectories: true)

    let runner = WorkflowPackageCommandRunner()
    let options = publishOptions(source: source, workingDirectory: tempDir, registryLocalPath: registryLocal, extra: [])
    let result = await runner.run(PackageCommand(kind: .publish, options: options))
    XCTAssertEqual(result.exitCode, .success, result.stderr)

    let recordPath = tempDir.appendingPathComponent(".riela/package-registry/demo-package.json")
    let record = try decodeJSON(JSONObject.self, from: String(contentsOf: recordPath))
    let checksum = try XCTUnwrap(record["checksum"]?.stringValue)
    XCTAssertNotEqual(checksum, "swift-deterministic-publish-record")
    XCTAssertEqual(record["checksumAlgorithm"]?.stringValue, "md5")
    let expected = try WorkflowPackageChecksum.md5(packageRoot: source)
    XCTAssertEqual(checksum, expected)
    guard case let .array(backendValues)? = record["backends"] else {
      return XCTFail("backends should be an array")
    }
    XCTAssertEqual(backendValues.compactMap(\.stringValue), ["codex-agent"])

    // Normalized manifest is written INSIDE the staged workflow copy (which
    // checkout reads), not at the package-key root — a root manifest would make
    // `package list` treat the registry-cache key directory as an installed
    // package and surface a duplicate.
    let manifestPath = registryLocal.appendingPathComponent("packages/demo-package/workflow/riela-package.json")
    XCTAssertTrue(FileManager.default.fileExists(atPath: manifestPath.path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: registryLocal.appendingPathComponent("packages/demo-package/riela-package.json").path
      ),
      "no manifest at the package-key root; it would be double-listed"
    )
    let manifest = try decodeJSON(JSONObject.self, from: String(contentsOf: manifestPath))
    XCTAssertEqual(manifest["checksumAlgorithm"]?.stringValue, "md5")
    XCTAssertEqual(manifest["workflowDirectory"]?.stringValue, ".")
  }

  func testDirectPublishCommitsAndPushesWhenPermitted() async throws {
    let tempDir = tempRoot("direct")
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let source = tempDir.appendingPathComponent("source", isDirectory: true)
    try makeWorkflowSource(at: source)
    let registryLocal = tempDir.appendingPathComponent("registry", isDirectory: true)
    try makeGitCheckout(at: registryLocal)

    let executor = FakeWorkflowPackageCommandExecutor()
    var runner = WorkflowPackageCommandRunner()
    runner.publishCommandExecutor = executor
    let options = publishOptions(source: source, workingDirectory: tempDir, registryLocalPath: registryLocal, extra: [])
    let result = await runner.run(PackageCommand(kind: .publish, options: options))
    XCTAssertEqual(result.exitCode, .success, result.stderr)

    let record = try decodeJSON(JSONObject.self, from: String(contentsOf: tempDir.appendingPathComponent(".riela/package-registry/demo-package.json")))
    XCTAssertEqual(record["mode"]?.stringValue, "direct")
    XCTAssertEqual(record["commitSha"]?.stringValue, "abc123def456")
    let argSequences = executor.invocationArguments()
    XCTAssertTrue(argSequences.contains { $0.first == "commit" })
    XCTAssertTrue(argSequences.contains { $0.first == "push" && !$0.contains("--dry-run") })
  }

  func testDirectPublishFailsWhenPushPermissionDenied() async throws {
    let tempDir = tempRoot("denied")
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let source = tempDir.appendingPathComponent("source", isDirectory: true)
    try makeWorkflowSource(at: source)
    let registryLocal = tempDir.appendingPathComponent("registry", isDirectory: true)
    try makeGitCheckout(at: registryLocal)

    let executor = FakeWorkflowPackageCommandExecutor()
    executor.canPush = false
    var runner = WorkflowPackageCommandRunner()
    runner.publishCommandExecutor = executor
    let options = publishOptions(source: source, workingDirectory: tempDir, registryLocalPath: registryLocal, extra: [])
    let result = await runner.run(PackageCommand(kind: .publish, options: options))
    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(failureMessage(result).contains("--create-pr"), failureMessage(result))
    // No commit should have been attempted after the permission probe failed.
    XCTAssertFalse(executor.invocationArguments().contains { $0.first == "commit" })
  }

  func testForcedPullRequestModeReportsPrUrl() async throws {
    let tempDir = tempRoot("pr")
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let source = tempDir.appendingPathComponent("source", isDirectory: true)
    try makeWorkflowSource(at: source)
    let registryLocal = tempDir.appendingPathComponent("registry", isDirectory: true)
    try makeGitCheckout(at: registryLocal)

    let executor = FakeWorkflowPackageCommandExecutor()
    let adapter = FakeWorkflowPackagePullRequestAdapter()
    var runner = WorkflowPackageCommandRunner()
    runner.publishCommandExecutor = executor
    runner.publishPullRequestAdapterFactory = { _ in adapter }
    let options = publishOptions(
      source: source,
      workingDirectory: tempDir,
      registryLocalPath: registryLocal,
      extra: ["--create-pr", "--pr-base", "release"]
    )
    let result = await runner.run(PackageCommand(kind: .publish, options: options))
    XCTAssertEqual(result.exitCode, .success, result.stderr)

    let record = try decodeJSON(JSONObject.self, from: String(contentsOf: tempDir.appendingPathComponent(".riela/package-registry/demo-package.json")))
    XCTAssertEqual(record["mode"]?.stringValue, "pull-request")
    XCTAssertEqual(record["prUrl"]?.stringValue, "https://github.com/acme/packages/pull/7")
    XCTAssertEqual(adapter.lastRequest?.base, "release")
    XCTAssertEqual(adapter.lastRequest?.branch, "riela/publish-demo-package")
  }

  func testPullRequestAdapterFailurePropagates() async throws {
    let tempDir = tempRoot("prfail")
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let source = tempDir.appendingPathComponent("source", isDirectory: true)
    try makeWorkflowSource(at: source)
    let registryLocal = tempDir.appendingPathComponent("registry", isDirectory: true)
    try makeGitCheckout(at: registryLocal)

    let executor = FakeWorkflowPackageCommandExecutor()
    let adapter = FakeWorkflowPackagePullRequestAdapter()
    adapter.result = .failure(WorkflowPackagePublishGitError.pullRequestFailed("gh not authenticated"))
    var runner = WorkflowPackageCommandRunner()
    runner.publishCommandExecutor = executor
    runner.publishPullRequestAdapterFactory = { _ in adapter }
    let options = publishOptions(
      source: source,
      workingDirectory: tempDir,
      registryLocalPath: registryLocal,
      extra: ["--create-pr"]
    )
    let result = await runner.run(PackageCommand(kind: .publish, options: options))
    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(failureMessage(result).contains("pull request"), failureMessage(result))
  }

  func testDirtyRegistryWorktreeRefusesBeforeStaging() async throws {
    for status in ["?? new-file.txt", "M  staged.txt"] {
      let tempDir = tempRoot("dirty")
      defer { try? FileManager.default.removeItem(at: tempDir) }
      let source = tempDir.appendingPathComponent("source", isDirectory: true)
      try makeWorkflowSource(at: source)
      let registryLocal = tempDir.appendingPathComponent("registry", isDirectory: true)
      try makeGitCheckout(at: registryLocal)

      let executor = FakeWorkflowPackageCommandExecutor()
      executor.dirtyStatus = status
      var runner = WorkflowPackageCommandRunner()
      runner.publishCommandExecutor = executor
      let options = publishOptions(source: source, workingDirectory: tempDir, registryLocalPath: registryLocal, extra: [])
      let result = await runner.run(PackageCommand(kind: .publish, options: options))
      XCTAssertEqual(result.exitCode, .failure, "status \(status) should refuse")
      XCTAssertTrue(failureMessage(result).contains("uncommitted"), failureMessage(result))
      // Nothing should have been staged into the registry checkout.
      XCTAssertFalse(FileManager.default.fileExists(atPath: registryLocal.appendingPathComponent("packages/demo-package").path))
      XCTAssertFalse(executor.invocationArguments().contains { $0.first == "commit" })
    }
  }

  func testRemoteMismatchRefusesPublish() async throws {
    let tempDir = tempRoot("mismatch")
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let source = tempDir.appendingPathComponent("source", isDirectory: true)
    try makeWorkflowSource(at: source)
    let registryLocal = tempDir.appendingPathComponent("registry", isDirectory: true)
    try makeGitCheckout(at: registryLocal)

    let executor = FakeWorkflowPackageCommandExecutor()
    executor.remoteURL = "https://github.com/somebody-else/packages"
    var runner = WorkflowPackageCommandRunner()
    runner.publishCommandExecutor = executor
    let options = publishOptions(source: source, workingDirectory: tempDir, registryLocalPath: registryLocal, extra: [])
    let result = await runner.run(PackageCommand(kind: .publish, options: options))
    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(failureMessage(result).contains("remote mismatch"), failureMessage(result))
  }

  func testDryRunPerformsNoGitMutation() async throws {
    let tempDir = tempRoot("dryrun")
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let source = tempDir.appendingPathComponent("source", isDirectory: true)
    try makeWorkflowSource(at: source)
    let registryLocal = tempDir.appendingPathComponent("registry", isDirectory: true)
    try makeGitCheckout(at: registryLocal)

    let executor = FakeWorkflowPackageCommandExecutor()
    var runner = WorkflowPackageCommandRunner()
    runner.publishCommandExecutor = executor
    let options = CLICommandOptions(
      scope: "project",
      command: "publish",
      target: source.path,
      arguments: [
        "--package-id", "demo-package",
        "--registry", "https://github.com/acme/packages",
        "--registry-local-path", registryLocal.path,
        "--working-dir", tempDir.path,
        "--dry-run",
        "--output", "json"
      ],
      output: .json
    )
    let result = await runner.run(PackageCommand(kind: .publish, options: options))
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let decoded = try decodeJSON(WorkflowPackageCommandResult.self, from: result.stdout)
    XCTAssertTrue(decoded.dryRun)
    XCTAssertTrue(executor.invocationArguments().isEmpty, "dry run must not invoke git")
    XCTAssertFalse(FileManager.default.fileExists(atPath: registryLocal.appendingPathComponent("packages/demo-package").path))
  }

  private func failureMessage(_ result: CLICommandResult) -> String {
    if !result.stderr.isEmpty {
      return result.stderr
    }
    if let decoded = try? decodeJSON(CLIUnsupportedCommandResult.self, from: result.stdout) {
      return decoded.error ?? result.stdout
    }
    return result.stdout
  }

  private func decodeJSON<T: Decodable>(_ type: T.Type, from stdout: String) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: Data(stdout.utf8))
  }
}
