import Foundation
import RielaAppSupport
import RielaCore
import XCTest

/// The console projection reads the runtime-environment status once per
/// instance and uses the shared presence rule, so loader-managed names are
/// not reported missing.
@MainActor
final class RuntimeEnvironmentSurfaceConsoleTests: XCTestCase {
  private final class Counter { var reads = 0 }

  func testConsoleInstanceReadsStatusOnceAndCountsLoaderManagedNames() throws {
    let candidate = RielaAppDaemonWorkflowCandidate(
      id: "project:console-env", workflowId: "console-env", displayName: "console-env",
      sourceDescription: "test", workflowDirectory: NSTemporaryDirectory(), workingDirectory: NSTemporaryDirectory(),
      eventRoot: nil, eventSources: [],
      requiredEnvironment: [
        RielaAppEnvRequirement(name: "FILE_KEY"), RielaAppEnvRequirement(name: "LOADER_KEY", secret: true),
        RielaAppEnvRequirement(name: "ABSENT_KEY")
      ]
    )
    var preference = RielaAppDaemonWorkflowPreference(identity: candidate.id)
    preference.configuration.environmentResolution = RuntimeEnvironmentConfiguration(sources: [
      RuntimeEnvironmentCommandSource(id: "loader", names: ["LOADER_KEY"], command: ["/bin/echo"])
    ])
    let instance = WorkflowInstance.configured(identity: candidate.id, source: candidate, preference: preference)

    func provider(status: RuntimeEnvironmentStatus, counter: Counter) -> RielaConsoleGraphQLProvider {
      RielaConsoleGraphQLProvider(
        profile: .default, state: RielaAppDaemonWorkflowState(), instances: [instance], sources: [candidate],
        revision: 1, sessionStoreRoot: NSTemporaryDirectory(),
        runtimeSnapshot: { _ in .init(status: .stopped, detail: "Inactive") },
        environment: { _ in ["FILE_KEY": "value"] },
        environmentStatus: { _ in counter.reads += 1; return status }
      )
    }

    let unprepared = Counter()
    let before = try XCTUnwrap(provider(status: .init(), counter: unprepared).consoleInstanceDetail(identity: candidate.id).item)
    XCTAssertEqual(unprepared.reads, 1)
    let presence = Dictionary(uniqueKeysWithValues: before.requiredEnvironment.map { ($0.name, $0.present) })
    XCTAssertEqual(presence, ["FILE_KEY": true, "LOADER_KEY": true, "ABSENT_KEY": false])

    let failed = Counter()
    let afterFailure = try XCTUnwrap(provider(
      status: .init(names: ["LOADER_KEY"], readiness: .failed, lastError: .sourceFailed), counter: failed
    ).consoleInstanceDetail(identity: candidate.id).item)
    XCTAssertEqual(failed.reads, 1)
    XCTAssertEqual(afterFailure.requiredEnvironment.first { $0.name == "LOADER_KEY" }?.present, false)
    XCTAssertEqual(afterFailure.environmentStatus?["lastError"], .string("environment_source_failed"))
  }
}
