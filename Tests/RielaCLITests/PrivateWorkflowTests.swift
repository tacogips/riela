import Foundation
import RielaAdapters
import RielaCore
import XCTest
@testable import RielaCLI

final class PrivateWorkflowTests: XCTestCase {
  private let schema: JSONObject = ["type": .string("object"), "required": .array([.string("status")]),
    "properties": .object(["status": .object(["const": .string("ok")])]), "additionalProperties": .bool(false)]

  func testSelectedSecretsUseStdinOnlyAndContainerIsRemoved() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("private-workflow-host")
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = PrivateWorkflowFixtureRunner()
    let output = try await host(runner, root: root).execute(input(), context: .init())
    XCTAssertEqual(output.payload, ["status": .string("ok")])
    let calls = await runner.calls
    XCTAssertEqual(calls.count, 3)
    XCTAssertTrue(calls[1].0.arguments.contains(PrivateWorkflowWorker.command))
    XCTAssertTrue(calls[0].0.arguments.contains("/tmp:rw,nosuid,nodev,noexec,size=256m"))
    XCTAssertTrue(calls[2].0.arguments.contains("--force"))
    for (configuration, _) in calls {
      XCTAssertFalse(configuration.arguments.joined().contains("SYNTHETIC_SECRET"))
      XCTAssertFalse(configuration.environment.values.contains(where: { $0.contains("SYNTHETIC_SECRET") }))
    }
    let request = try JSONDecoder().decode(PrivateWorkflowRequest.self, from: Data(calls[1].1.utf8))
    XCTAssertEqual(request.credentials.first?.value, "SYNTHETIC_SECRET_FILE")
    XCTAssertEqual(request.environment, ["X_GW_TOKEN": "SYNTHETIC_SECRET_TOKEN"])
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
  }

  func testCancellationStillRemovesOwnedContainer() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("private-workflow-cancel")
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = PrivateWorkflowFixtureRunner(cancel: true)
    do {
      _ = try await host(runner, root: root).execute(input(), context: .init()); XCTFail("must cancel")
    } catch { XCTAssertTrue(error is CancellationError) }
    let calls = await runner.calls
    XCTAssertEqual(calls.count, 3)
    XCTAssertTrue(calls.last?.0.arguments.contains("--force") == true)
  }

  func testControllerRejectsUnapprovedPayloadAndProviderEvents() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("private-workflow-output")
    defer { try? FileManager.default.removeItem(at: root) }
    for event in [false, true] {
      let runner = PrivateWorkflowFixtureRunner(invalidPayload: !event, event: event)
      do {
        _ = try await host(runner, root: root).execute(input(), context: .init()); XCTFail("must reject")
      } catch { XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidOutput) }
    }
  }

  func testGuestPrivilegeAndMountChecksRejectUnsafeBoundaries() throws {
    let status = "NoNewPrivs:\t1\nCapEff:\t0\nCapPrm:\t0\nCapBnd:\t0\nCapAmb:\t0\n"
    let mounts = "1 0 0:1 / / ro - ext4 disk rw\n2 1 0:2 / /tmp rw,nosuid,nodev,noexec - tmpfs tmpfs rw\n"
    try PrivateWorkflowWorker.verifyGuestMetadata(status: [status], mounts: mounts, temporaryBytes: 256 * 1024 * 1024)
    for (statuses, table, bytes) in [
      ([status.replacingOccurrences(of: "NoNewPrivs:\t1", with: "NoNewPrivs:\t0")], mounts, UInt64(1024)),
      ([status, status.replacingOccurrences(of: "CapEff:\t0", with: "CapEff:\t1")], mounts, UInt64(1024)),
      ([status], mounts.replacingOccurrences(of: "nosuid,nodev,noexec", with: "nosuid,nodev"), UInt64(1024)),
      ([status], mounts.replacingOccurrences(of: "/ / ro", with: "/ / rw"), UInt64(1024)),
      ([status], mounts, UInt64(257 * 1024 * 1024))
    ] {
      XCTAssertThrowsError(try PrivateWorkflowWorker.verifyGuestMetadata(status: statuses, mounts: table, temporaryBytes: bytes))
    }
    XCTAssertThrowsError(try PrivateWorkflowWorker.verifyGuestMetadata(status: [status + "NoNewPrivs:\t1\n"],
      mounts: mounts, temporaryBytes: 1024))
  }

  func testEmbeddedGraphKeepsIntermediateDataOutOfValidatedRoot() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("private-workflow-inner")
    defer { try? FileManager.default.removeItem(at: root) }
    let definitions = root.appendingPathComponent("definitions/check")
    try FileManager.default.createDirectory(at: definitions, withIntermediateDirectories: true)
    let workflow: JSONObject = ["workflowId": .string("check"), "description": .string("synthetic private graph"),
      "defaults": .object(["nodeTimeoutMs": .number(30000), "maxLoopIterations": .number(1)]), "entryStepId": .string("fetch"),
      "nodes": .array([("fetch", ["raw": JSONValue.string("RAW_INTERMEDIATE_CANARY")]),
        ("checked", ["status": JSONValue.string("ok")])].map { id, payload in
          .object(["id": .string(id), "addon": .object(["name": .string("riela/json-compose"), "version": .string("1"),
            "config": .object(["payload": .object(payload)])])])
        }), "steps": .array([
          .object(["id": .string("fetch"), "nodeId": .string("fetch"),
            "transitions": .array([.object(["toStepId": .string("checked")])])]),
          .object(["id": .string("checked"), "nodeId": .string("checked")])])]
    try JSONEncoder().encode(workflow).write(to: definitions.appendingPathComponent("workflow.json"))
    let plan = try PrivateWorkflowPlan(config: ["workflowId": .string("check"),
      "definitionRoot": .string(definitions.deletingLastPathComponent().path), "outputSchema": .object(schema)])
    let output = try await PrivateWorkflowWorker.executeWorkflow(.init(plan: plan,
      deadline: Date().addingTimeInterval(30), environment: [:], credentials: []), root: root.appendingPathComponent("guest"))
    XCTAssertEqual(output.payload, ["status": .string("ok")])
    XCTAssertEqual(output.promptText, "")
    XCTAssertNil(output.usage)
    XCTAssertFalse(try XCTUnwrap(String(data: JSONEncoder().encode(output), encoding: .utf8)).contains("RAW_INTERMEDIATE_CANARY"))
  }

  func testBuiltinRoutingRequiresPrivateSandboxAndUsesOwnedWorker() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("private-workflow-dispatch")
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = PrivateWorkflowFixtureRunner()
    let environment = host(runner, root: root).environment
    let primary = BuiltinWorkflowAddonResolver(environment: environment)
    let resolver = BuiltinAddonContainerResolver(primary: primary, environment: environment,
      workingDirectory: root, runner: runner)
    let output = try await resolver.execute(input(), context: .init())
    XCTAssertEqual(output.payload, ["status": .string("ok")])
    let calls = await runner.calls
    XCTAssertTrue(calls[1].0.arguments.contains(PrivateWorkflowWorker.command))
    var unsandboxed = input()
    unsandboxed.addon.sandbox = nil
    do {
      _ = try await resolver.execute(unsandboxed, context: .init()); XCTFail("host fallback must be refused")
    } catch { XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked) }
  }

  func testInvalidPlansAndEnvironmentAreRefusedBeforeContainerLaunch() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("private-workflow-invalid")
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = PrivateWorkflowFixtureRunner()
    for addition: JSONObject in [
      ["workflowId": .string("../escape")], ["definitionRoot": .string("/app/../outside")],
      ["maxSteps": .integer(0)], ["maxConcurrency": .integer(17)], ["timeoutSeconds": .integer(0)],
      ["command": .string("arbitrary")], ["outputSchema": .object(["type": .string("invalid-schema-type")])]
    ] {
      var invalid = input()
      invalid.addon.config?.merge(addition) { _, value in value }
      do {
        _ = try await host(runner, root: root).execute(invalid, context: .init()); XCTFail("invalid plan accepted")
      } catch { /* Decoder and contract errors both stop before transport. */ }
    }
    for name in ["HOME", "PATH", "RIELA_MEMORY_ROOT", "LD_PRELOAD", "PYTHONPATH", "NODE_OPTIONS"] {
      var invalid = input()
      invalid.addon.env = [name: .object(["fromEnv": .string("SOURCE_SECRET")])]
      do {
        _ = try await host(runner, root: root).execute(invalid, context: .init()); XCTFail("reserved binding accepted")
      } catch { XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidInput) }
    }
    let calls = await runner.calls
    XCTAssertTrue(calls.isEmpty)
  }

  private func input() -> WorkflowAddonExecutionInput {
    .init(workflowId: "outer", stepId: "private", nodeId: "private", addon: .init(name: "riela/private-workflow", version: "1",
      config: ["workflowId": .string("synthetic"), "outputSchema": .object(schema)],
      env: ["X_GW_TOKEN": .object(["fromEnv": .string("SOURCE_SECRET")])],
      sandbox: .init(backend: .container, networkPolicy: .denied, container: .init(image: "fixture:local"),
        ephemeralHome: true, credentialEnvironment: ["MODEL_SECRET": ".codex/auth.json"])),
      variables: [:], resolvedInputPayload: [:])
  }

  private func host(_ runner: PrivateWorkflowFixtureRunner, root: URL) -> PrivateWorkflowHost {
    let worker = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent(".build/debug/riela").resolvingSymlinksInPath().path
    return .init(environment: ["RIELA_CONTAINER_RUNTIME": "docker", "RIELA_SANDBOX_WORKER_EXECUTABLE": worker,
      "SOURCE_SECRET": "SYNTHETIC_SECRET_TOKEN", "MODEL_SECRET": "SYNTHETIC_SECRET_FILE"],
      workingDirectory: root, runner: runner, directoryParent: root)
  }
}

private actor PrivateWorkflowFixtureRunner: LocalProcessRunning {
  var calls: [(LocalProcessConfiguration, String)] = []
  var cancel: Bool
  var invalidPayload: Bool
  var event: Bool
  init(cancel: Bool = false, invalidPayload: Bool = false, event: Bool = false) {
    self.cancel = cancel; self.invalidPayload = invalidPayload; self.event = event
  }
  func run(configuration: LocalProcessConfiguration, stdin: String, deadline: Date?) async throws -> LocalProcessResult {
    calls.append((configuration, stdin))
    guard configuration.arguments.contains("exec") else { return .init(stdout: "", stderr: "", terminationStatus: 0) }
    if cancel { throw CancellationError() }
    let output = AdapterExecutionOutput(provider: "fixture", model: "fixture", promptText: "", completionPassed: true,
      payload: invalidPayload ? ["raw": .string("RAW_UNAPPROVED")] : ["status": .string("ok")])
    let record = SandboxNodeRecord(kind: event ? .event : .result, output: event ? nil : output)
    let stdout = try XCTUnwrap(String(data: JSONEncoder().encode(record), encoding: .utf8))
    return .init(stdout: stdout + "\n", stderr: "", terminationStatus: 0)
  }
}
