import Foundation
import RielaAdapters
import RielaCore
import XCTest
@testable import RielaCLI

/// Issue #195: opt-in disk budgeting and native reclamation for container builds.
final class ContainerStorageTests: XCTestCase {
  func testPolicyIsOptInAndLayersUserProjectAndEnvironment() throws {
    let root = try makeRielaCLITestTemporaryDirectory("container-storage-policy")
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home")
    let project = root.appendingPathComponent("project")
    XCTAssertEqual(try ContainerStoragePolicy.resolve(homeDirectory: home.path, projectDirectory: project.path,
      environment: ["HOME": home.path]), ContainerStoragePolicy())

    try writeConfig(home, #"{"containerStorage":{"minimumFreeMiB":4096,"buildCacheBudgetMiB":2048}}"#)
    try writeConfig(project, #"{"containerStorage":{"buildCacheBudgetMiB":1024,"commandTimeoutSeconds":30}}"#)
    var policy = try ContainerStoragePolicy.resolve(homeDirectory: home.path, projectDirectory: project.path,
      environment: ["HOME": home.path])
    XCTAssertEqual(policy, ContainerStoragePolicy(minimumFreeMiB: 4096, buildCacheBudgetMiB: 1024, commandTimeoutSeconds: 30))

    policy = try ContainerStoragePolicy.resolve(homeDirectory: home.path, projectDirectory: project.path,
      environment: ["HOME": home.path, "RIELA_CONTAINER_MIN_FREE_MIB": "0", "RIELA_CONTAINER_BUILD_CACHE_BUDGET_MIB": "512"])
    XCTAssertNil(policy.minimumFreeMiB)
    XCTAssertEqual(policy.buildCacheBudgetMiB, 512)

    try writeConfig(project, #"{"containerStorage":{"keepEverything":true}}"#)
    XCTAssertThrowsError(try ContainerStoragePolicy.resolve(homeDirectory: home.path, projectDirectory: project.path,
      environment: ["HOME": home.path]))
    try writeConfig(project, #"{"containerStorage":{"minimumFreeMiB":-1}}"#)
    XCTAssertThrowsError(try ContainerStoragePolicy.resolve(homeDirectory: home.path, projectDirectory: project.path,
      environment: ["HOME": home.path]))
  }

  func testReclaimPrunesOnlyBuildCacheOfRunningBuilder() async throws {
    let runner = RecordingRunner(responses: [
      "builder status --format json": .init(stdout: #"[{"status":"running"}]"#, status: 0),
      "system df --format json": .init(stdout: #"{"images":{"sizeInBytes":10}}"#, status: 0)
    ])
    let maintenance = makeMaintenance(policy: .init(minimumFreeMiB: nil, buildCacheBudgetMiB: 2048), runner: runner)
    let report = await maintenance.report(reclaim: true, keepStorageMiB: nil)
    let commands = runner.commands()
    XCTAssertEqual(commands, [
      "builder status --format json",
      "exec buildkit buildctl prune --all --keep-storage 2048",
      "clean buildkit",
      "system df --format json"
    ])
    let destructive = ["image", "volume", "rm", "delete", "prune"]
    XCTAssertFalse(commands.contains { command in
      let words = command.split(separator: " ").map(String.init)
      return words.first.map(destructive.contains) ?? false || words.contains("image") || words.contains("volume")
    })
    XCTAssertEqual(report.builder, "running")
    XCTAssertEqual(report.reclaim?.compactMap(\.exitCode), [0, 0])
    XCTAssertEqual(report.status, "ok")
  }

  func testStoppedBuilderIsNeverStartedAndTimeoutsAreDiagnostics() async throws {
    let stopped = RecordingRunner(responses: ["builder status --format json": .init(stdout: #"[{"status":"stopped"}]"#, status: 0)])
    let outcomes = await makeMaintenance(policy: .init(), runner: stopped).reclaimBuildCache(keepStorageMiB: 100)
    XCTAssertEqual(stopped.commands(), ["builder status --format json"])
    XCTAssertEqual(outcomes.first?.diagnostic, "builder stopped; nothing to reclaim")

    let hanging = RecordingRunner(responses: [:], failure: AdapterExecutionError(.timeout, "deadline"))
    let report = await makeMaintenance(policy: .init(), runner: hanging).report(reclaim: true, keepStorageMiB: 10)
    XCTAssertEqual(report.builder, "unknown")
    XCTAssertTrue(report.diagnostics.contains { $0.contains("container system df unavailable") }, "\(report.diagnostics)")
  }

  func testLowSpaceGateReclaimsOnceThenRefusesWithoutDispatch() async throws {
    let runner = RecordingRunner(responses: ["builder status --format json": .init(stdout: #"[{"status":"running"}]"#, status: 0)])
    var maintenance = makeMaintenance(policy: .init(minimumFreeMiB: 1024, buildCacheBudgetMiB: 256), runner: runner)
    maintenance.capacityProbe = { _ in 10 * 1_048_576 }
    do {
      try await maintenance.ensureCapacity(addonName: "media/download")
      XCTFail("expected refusal")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.effectOutcome, .notDispatched)
      XCTAssertEqual(error.isRetryable, false)
      XCTAssertTrue(error.message.hasPrefix("insufficient_disk_space"), error.message)
    }
    XCTAssertTrue(runner.commands().contains("exec buildkit buildctl prune --all --keep-storage 256"))

    maintenance.capacityProbe = { _ in 4096 * 1_048_576 }
    try await maintenance.ensureCapacity(addonName: "media/download")
    maintenance.policy.minimumFreeMiB = nil
    maintenance.capacityProbe = { _ in 0 }
    try await maintenance.ensureCapacity(addonName: "media/download")
  }

  func testCommandReportsLowStatusWithExitThree() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("container-storage-cli")
    defer { try? FileManager.default.removeItem(at: root) }
    var command = ContainerStorageCommandRunner(environment: ["HOME": root.path, "RIELA_CONTAINER_MIN_FREE_MIB": "1",
      "PATH": "/nonexistent"])
    command.makeMaintenance = { maintenance in
      var copy = maintenance
      copy.driver = nil
      copy.capacityProbe = { _ in 0 }
      return copy
    }
    let result = await command.run(["--working-dir", root.path])
    XCTAssertEqual(result.exitCode, .gateCheckFailed, result.stderr)
    let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    XCTAssertEqual(json["status"] as? String, "low")
    let usage = await command.run(["--keep-storage-mib", "5"])
    XCTAssertEqual(usage.exitCode, .usage)
    let help = await RielaCLIApplication().run(["storage", "container", "--help"])
    XCTAssertEqual(help.exitCode, .success)
    XCTAssertTrue(help.stdout.contains("riela storage container"), help.stdout)
  }

  private func makeMaintenance(policy: ContainerStoragePolicy, runner: RecordingRunner) -> ContainerStorageMaintenance {
    var maintenance = ContainerStorageMaintenance(driver: AppleContainerDriver(executable: "/usr/local/bin/container"),
      policy: policy, workingDirectory: FileManager.default.temporaryDirectory, environment: ["HOME": "/nonexistent-home"],
      runner: runner)
    maintenance.capacityProbe = { _ in 100 * 1_073_741_824 }
    return maintenance
  }

  private func writeConfig(_ directory: URL, _ json: String) throws {
    let riela = directory.appendingPathComponent(".riela")
    try FileManager.default.createDirectory(at: riela, withIntermediateDirectories: true)
    try Data(json.utf8).write(to: riela.appendingPathComponent("config.json"))
  }
}

private final class RecordingRunner: LocalProcessRunning, @unchecked Sendable {
  struct Response { var stdout: String; var status: Int32 }
  private let lock = NSLock()
  private var recorded: [String] = []
  private let responses: [String: Response]
  private let failure: (any Error)?

  init(responses: [String: Response], failure: (any Error)? = nil) {
    self.responses = responses
    self.failure = failure
  }

  func commands() -> [String] { lock.lock(); defer { lock.unlock() }; return recorded }

  func run(configuration: LocalProcessConfiguration, stdin: String, deadline: Date?) async throws -> LocalProcessResult {
    let key = configuration.arguments.joined(separator: " ")
    lock.withLock { recorded.append(key) }
    if let failure { throw failure }
    let response = responses[key] ?? Response(stdout: "", status: 0)
    return LocalProcessResult(stdout: response.stdout, stderr: "", terminationStatus: response.status)
  }
}
