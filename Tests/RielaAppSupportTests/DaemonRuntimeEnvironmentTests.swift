#if os(macOS)
import Foundation
import RielaCore
import RielaServer
@testable import RielaAppSupport
import XCTest

private actor DaemonEnvironmentRunner: RuntimeEnvironmentCommandRunning {
  private var calls = 0
  func run(source: RuntimeEnvironmentCommandSource, baseEnvironment: [String: String], maxOutputBytes: Int) async throws -> Data {
    calls += 1
    if calls > 1 { throw RuntimeEnvironmentError.sourceFailed }
    return Data("{\"TOKEN\":\"synthetic-private-canary\"}".utf8)
  }
  func count() -> Int { calls }
}

final class DaemonRuntimeEnvironmentTests: XCTestCase {
  private func candidate(_ identity: String = "7:defaultfixture") -> RielaAppDaemonWorkflowCandidate {
    RielaAppDaemonWorkflowCandidate(
      id: identity, workflowId: "fixture", displayName: "Fixture", sourceDescription: "fixture",
      workflowDirectory: "/fixture", workingDirectory: "/fixture", eventRoot: nil, eventSources: [],
      requiredEnvironment: [RielaAppEnvRequirement(name: "TOKEN", secret: true)]
    )
  }

  @MainActor
  func testPrepareSharedByManualAndStartAndFailedReloadRetainsSnapshot() async throws {
    let runner = DaemonEnvironmentRunner()
    let runtime = RielaAppDaemonWorkflowRuntime(
      monitorIntervalNanoseconds: 0, environmentStore: RuntimeEnvironmentSnapshotStore(runner: runner)
    )
    let configuration = WorkflowServeRuntimeConfiguration(
      inheritedEnvironment: ["NON_SECRET": "first"],
      environmentResolution: RuntimeEnvironmentConfiguration(sources: [
        RuntimeEnvironmentCommandSource(id: "fixture", names: ["TOKEN"], command: ["/fixture"])
      ]), environmentProfile: "default"
    )
    let first = try await runtime.prepareEnvironment(for: candidate(), configuration: configuration)
    let second = try await runtime.prepareEnvironment(for: candidate(), configuration: configuration)
    XCTAssertEqual(first.generation, second.generation)
    let count = await runner.count()
    XCTAssertEqual(count, 1)
    do {
      _ = try await runtime.reloadEnvironment(for: candidate(), configuration: configuration)
      XCTFail("reload should fail")
    } catch { XCTAssertEqual(error as? RuntimeEnvironmentError, .sourceFailed) }
    let retained = try await runtime.prepareEnvironment(for: candidate(), configuration: configuration)
    XCTAssertEqual(retained.runtimeEnvironment()["TOKEN"], "synthetic-private-canary")
    let status = runtime.cachedEnvironmentStatus(identity: candidate().id, profile: "default")
    XCTAssertEqual(status.readiness, .ready)
    XCTAssertEqual(status.lastError, .sourceFailed)
    XCTAssertFalse((String(bytes: try JSONEncoder().encode(status), encoding: .utf8) ?? "encoding-failed").contains("synthetic-private-canary"))
    XCTAssertNil(configuration.runtimeEnvironmentValues)
    XCTAssertNil(configuration.inheritedEnvironment["TOKEN"])
  }

  @MainActor
  func testProfileMismatchAndMissingRequiredBlockBeforeControllerStart() async throws {
    let runtime = RielaAppDaemonWorkflowRuntime(monitorIntervalNanoseconds: 0)
    let wrong = WorkflowServeRuntimeConfiguration(environmentProfile: "other")
    do {
      _ = try await runtime.prepareEnvironment(for: candidate(), configuration: wrong)
      XCTFail("profile mismatch must fail")
    } catch { XCTAssertEqual(error as? RuntimeEnvironmentError, .invalidConfiguration) }
    await runtime.start(candidate(), configuration: WorkflowServeRuntimeConfiguration(environmentProfile: "default"))
    XCTAssertEqual(runtime.snapshot(for: candidate().id).status, .failed)
    XCTAssertEqual(runtime.snapshot(for: candidate().id).detail, "environment_required_missing")
    let status = await runtime.environmentStatus(identity: candidate().id, profile: "default")
    XCTAssertEqual(status.missingNames, ["TOKEN"])
    XCTAssertEqual(status.readiness, .failed)
  }
}
#endif
