import Foundation
import RielaCore
import RielaGraphQL
import RielaServer
@testable import RielaAppSupport
import XCTest

private struct BoundaryEnvironmentRunner: RuntimeEnvironmentCommandRunning {
  let value: String
  func run(source: RuntimeEnvironmentCommandSource, baseEnvironment: [String: String], maxOutputBytes: Int) async throws -> Data {
    try JSONEncoder().encode(["BOUNDARY_SECRET": value])
  }
}

final class RuntimeEnvironmentAppBoundaryTests: XCTestCase {
  func testLoadedCanaryNeverEntersPersistableConfigurationOrSafeProjections() async throws {
    let canary = "runtime-only-" + UUID().uuidString
    let descriptor = RuntimeEnvironmentConfiguration(required: ["BOUNDARY_SECRET"], sources: [
      .init(id: "fixture", names: ["BOUNDARY_SECRET"], command: ["fixture-loader"], format: .json, timeoutSeconds: 2)
    ])
    let instance = WorkflowInstanceConfiguration(environmentResolution: descriptor, defaultVariables: ["public": .string("value")])
    let decoded = try JSONDecoder().decode(WorkflowInstanceConfiguration.self, from: JSONEncoder().encode(instance))
    XCTAssertEqual(decoded.environmentResolution, descriptor)
    XCTAssertTrue(decoded.environmentVariables.isEmpty)
    let store = RuntimeEnvironmentSnapshotStore(runner: BoundaryEnvironmentRunner(value: canary))
    let scope = RuntimeEnvironmentScope(profile: "test", instanceIdentity: "one")
    let snapshot = try await store.prepare(scope: scope, configuration: descriptor, requiredNames: [], baseEnvironment: ["PATH": "/usr/bin"])
    XCTAssertEqual(snapshot.runtimeEnvironment()["BOUNDARY_SECRET"], canary)
    var serving = instance.serveConfiguration(inheritedEnvironment: ["PATH": "/usr/bin"])
    serving.runtimeEnvironmentValues = snapshot.runtimeEnvironment()
    serving.runtimeEnvironmentNames = snapshot.names
    serving.runtimeEnvironmentGeneration = snapshot.generation
    let status = await store.status(scope: scope)
    let console = GraphQLConsoleInstanceDTO(id: "one", sourceId: "source", isDefault: false, name: "one", workflowId: "test", source: "fixture", sourceKind: "directory", status: "running", statusDetail: "running", active: true, enabledAtLaunch: true, environmentResolution: descriptor)
    for data in [try JSONEncoder().encode(instance), try JSONEncoder().encode(serving), try JSONEncoder().encode(status), try JSONEncoder().encode(console)] {
      XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(canary))
    }
    XCTAssertFalse(String(describing: snapshot).contains(canary))
    XCTAssertEqual(try JSONDecoder().decode(WorkflowServeRuntimeConfiguration.self, from: JSONEncoder().encode(serving)).runtimeEnvironmentValues, nil)
  }

  func testPrivatePipeAcknowledgesManagedNamesIncludingAbsentOptionalAndDiscardsRawOutput() async throws {
    let script = "import sys,json\nfor line in sys.stdin:\n f=json.loads(line); print('private-canary-never-retained',file=sys.stderr,flush=True); print(json.dumps({'type':'runtime-environment-ack','generation':f['generation'],'names':f['managedNames'],'accepted':True}),flush=True)"
    var command = RielaAppDaemonEventServeCommand(executablePath: "/usr/bin/python3", arguments: ["-u", "-c", script], workingDirectory: FileManager.default.currentDirectoryPath, environment: [:])
    command.runtimeEnvironmentGeneration = 1
    command.runtimeEnvironmentNames = ["OPTIONAL", "SECRET"]
    let process = try DefaultEventServeProcessLauncher().launch(command)
    do {
      try await process.updateRuntimeEnvironment(generation: 1, names: command.runtimeEnvironmentNames, values: ["SECRET": "fixture-only"])
      try await process.updateRuntimeEnvironment(generation: 2, names: command.runtimeEnvironmentNames, values: [:])
      XCTAssertEqual(process.capturedOutput, "")
    } catch {
      await process.terminate()
      throw error
    }
    await process.terminate()
    XCTAssertFalse(process.isRunning)
  }

  func testReloadActionDoesNotChangePersistedInstanceState() throws {
    let input = try JSONDecoder().decode(WorkflowInstanceActionInput.self, from: Data(#"{"action":"reloadEnvironment","expectedProfile":"default","expectedRevision":1}"#.utf8))
    let original = RielaAppDaemonWorkflowPreference(identity: "one", available: true, active: true)
    XCTAssertEqual(input.action.applying(to: original), original)
    XCTAssertFalse(input.action.startsRuntime)
    XCTAssertFalse(input.action.stopsRuntime)
  }
}
