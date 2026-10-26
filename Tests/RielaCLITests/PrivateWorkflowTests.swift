import Foundation
import RielaAdapters
import RielaCore
import RielaSQLite
import XCTest
@testable import RielaCLI

final class PrivateWorkflowTests: XCTestCase {
  private let schema: JSONObject = ["type": .string("object"), "required": .array([.string("status")]),
    "properties": .object(["status": .object(["const": .string("ok")])]), "additionalProperties": .bool(false)]

  func testUsageExportReachesHostCacheEvenWhenPrivateResultIsRejected() async throws {
    for invalid in [false, true] {
      let root = try makeRielaCLITestTemporaryDirectory("private-usage-export")
      defer { try? FileManager.default.removeItem(at: root) }
      // The guest emits one compact JSON line per observation; the host reads stderr line by line.
      let telemetry: JSONValue = .object(["data": .object(["extensions": .object(["resourceUsage": .object([
        "version": .integer(1), "basis": .string("upstream-response"), "billingStatus": .string("not-reported"),
        "httpResponses": .integer(1), "successfulResponses": .integer(1), "unclassifiedResources": .integer(0),
        "resources": .array([.object(["kind": .string("post"), "idHash": .string(String(repeating: "a", count: 64)),
          "utcDay": .string("2026-10-24")])])])])])])
      let runner = PrivateWorkflowFixtureRunner(invalidPayload: invalid,
        usageLine: XGatewayUsageTransport.prefix + (try telemetry.compactJSONString()))
      var controller = host(runner, root: root)
      controller.environment["RIELA_CACHE_ROOT"] = root.appendingPathComponent("host-cache").path
      var request = input(); request.addon.config?["xUsageScope"] = .string("fixture-app")
      let events = PrivateWorkflowEventRecorder()
      let context = AdapterExecutionContext(backendEventHandler: { await events.append($0) })
      do {
        let output = try await controller.execute(request, context: context)
        XCTAssertFalse(invalid)
        XCTAssertEqual(output.payload, ["status": .string("ok")])
      } catch { XCTAssertTrue(invalid) }
      let usageInput = WorkflowAddonExecutionInput(workflowId: "test", stepId: "read", nodeId: "read",
        addon: .init(name: "riela/x-gateway-read", config: ["usageCache": .bool(true), "usageScope": .string("fixture-app")]))
      let cache = try XCTUnwrap(XGatewayUsageCacheExchange(input: usageInput, workingDirectory: root,
        environment: controller.environment))
      let keys = try cache.store.keys(cacheId: XGatewayUsageCacheExchange.cacheId, scope: XGatewayUsageCacheExchange.scope)
      XCTAssertEqual(keys.count, 1)
      let rows = try cache.store.get(cacheId: XGatewayUsageCacheExchange.cacheId,
        scope: XGatewayUsageCacheExchange.scope, keys: keys)
      let entry = try JSONDecoder().decode(JSONObject.self,
        from: JSONEncoder().encode(try XCTUnwrap(rows.results.first?.entry?.payload)))
      XCTAssertEqual(entry["telemetryStatus"], .string("stored"))
      guard case let .object(observation)? = entry["observation"], case let .array(resources)? = observation["resources"] else {
        return XCTFail("stored usage row has no normalized observation")
      }
      XCTAssertEqual(resources.count, 1)
      let recorded = await events.events
      XCTAssertEqual(recorded.count, 1)
      XCTAssertEqual(recorded.first?.eventType, "x-resource-usage-cache")
      XCTAssertEqual(recorded.first?.metadata?["statuses"], .object(["stored": .integer(1)]))
    }
  }

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
    XCTAssertEqual(request.version, PrivateWorkflowRequest.currentVersion)
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

  func testExplicitTemporaryStorageAllocatesBoundedGuestMemory() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("private-workflow-storage")
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = PrivateWorkflowFixtureRunner()
    var request = input()
    request.addon.config?["temporaryStorageMiB"] = .integer(1024)
    _ = try await host(runner, root: root).execute(request, context: .init())
    let calls = await runner.calls
    let arguments = try XCTUnwrap(calls.first?.0.arguments)
    XCTAssertTrue(arguments.contains("/tmp:rw,nosuid,nodev,noexec,size=1024m"))
    let index = try XCTUnwrap(arguments.firstIndex(of: "--memory"))
    XCTAssertEqual(arguments[index + 1], "2048M")
    for value: JSONValue in [.integer(0), .integer(63), .integer(4097), .number(256.5), .string("1024")] {
      var config = try XCTUnwrap(input().addon.config)
      config["temporaryStorageMiB"] = value
      XCTAssertThrowsError(try PrivateWorkflowPlan(config: config))
    }
  }

  func testAdmissionWaitDoesNotLaunchPrivateWorkerAndCanProceedAfterRelease() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("private-workflow-admission")
    defer { try? FileManager.default.removeItem(at: root) }
    let pool = root.appendingPathComponent("pool")
    let policy = WorkflowExecutionAdmission(directoryEnvironment: "MODEL_POOL", capacity: 1)
    var held = try await SandboxExecutionAdmission.acquire(policy, environment: ["MODEL_POOL": pool.path], deadline: nil)
    XCTAssertNotNil(held)
    let runner = PrivateWorkflowFixtureRunner()
    var controller = host(runner, root: root)
    controller.environment["MODEL_POOL"] = pool.path
    var request = input(); request.addon.sandbox?.admission = policy
    do {
      _ = try await controller.execute(request, context: .init(deadline: Date().addingTimeInterval(0.05)))
      XCTFail("busy pool must not launch a container")
    } catch { XCTAssertEqual((error as? AdapterExecutionError)?.code, .timeout) }
    let before = await runner.calls
    XCTAssertTrue(before.isEmpty)
    held = nil
    let output = try await controller.execute(request, context: .init(deadline: Date().addingTimeInterval(5)))
    XCTAssertEqual(output.payload, ["status": .string("ok")])
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

  func testHostForcesRoutingAndModelMetadataInsteadOfTrustingGuest() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("private-workflow-metadata")
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = PrivateWorkflowFixtureRunner(when: ["PRIVATE SOURCE SENTENCE": true], model: "PRIVATE MODEL TEXT",
      provider: "PRIVATE PROVIDER")
    let output = try await host(runner, root: root).execute(input(), context: .init())
    XCTAssertEqual(output.when, ["always": true])
    XCTAssertEqual(output.model, "synthetic")
    XCTAssertEqual(output.provider, "riela-private-workflow")
    XCTAssertFalse(try XCTUnwrap(String(data: JSONEncoder().encode(output), encoding: .utf8)).contains("PRIVATE"))
  }

  func testWorkerExitStatusesUseSharedFixedMapping() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("private-workflow-exit")
    defer { try? FileManager.default.removeItem(at: root) }
    for (status, expected) in [
      (PrivateWorkflowWorker.guestRefusalStatus,
        AdapterExecutionError(.policyBlocked, "private worker refused the guest identity or resource limits")),
      (Int32(137), AdapterExecutionError(.providerError, "private workflow worker exited with status 137"))
    ] {
      let runner = PrivateWorkflowFixtureRunner(status: status)
      do {
        _ = try await host(runner, root: root).execute(input(), context: .init()); XCTFail("non-zero exit accepted")
      } catch let error as AdapterExecutionError { XCTAssertEqual(error, expected) }
    }
  }

  func testHostRefusesRecordsFromOlderPrivateWorker() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("private-workflow-old-worker")
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = PrivateWorkflowFixtureRunner(recordVersion: 1)
    do {
      _ = try await host(runner, root: root).execute(input(), context: .init()); XCTFail("old worker record accepted")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertTrue(error.message.contains("older record protocol"))
    }
  }

  func testStaticRefusalDoesNotWaitForBusyAdmissionPool() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("private-workflow-admission-order")
    defer { try? FileManager.default.removeItem(at: root) }
    let pool = root.appendingPathComponent("pool")
    let policy = WorkflowExecutionAdmission(directoryEnvironment: "MODEL_POOL", capacity: 1)
    let held = try await SandboxExecutionAdmission.acquire(policy, environment: ["MODEL_POOL": pool.path], deadline: nil)
    defer { withExtendedLifetime(held) {} }
    let runner = PrivateWorkflowFixtureRunner()
    var controller = host(runner, root: root)
    controller.environment["MODEL_POOL"] = pool.path
    controller.environment["RIELA_SANDBOX_WORKER_EXECUTABLE"] = root.appendingPathComponent("missing-worker").path
    var request = input(); request.addon.sandbox?.admission = policy
    let started = Date()
    do {
      _ = try await controller.execute(request, context: .init(deadline: Date().addingTimeInterval(5)))
      XCTFail("missing worker accepted")
    } catch { XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked) }
    XCTAssertLessThan(Date().timeIntervalSince(started), 2, "static refusal must not wait for a pool slot")
    let calls = await runner.calls
    XCTAssertTrue(calls.isEmpty)
  }

  func testInnerTimeoutKeepsTimeoutClassAndFailuresStayFinite() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("private-workflow-timeout")
    defer { try? FileManager.default.removeItem(at: root) }
    let definitions = root.appendingPathComponent("definitions/slow")
    try FileManager.default.createDirectory(at: definitions.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    let workflow: JSONObject = ["workflowId": .string("slow"), "description": .string("synthetic slow private graph"),
      "defaults": .object(["nodeTimeoutMs": .number(30000), "maxLoopIterations": .number(1)]), "entryStepId": .string("wait"),
      "nodes": .array([.object(["id": .string("wait"), "nodeFile": .string("nodes/wait.json")])]),
      "steps": .array([.object(["id": .string("wait"), "nodeId": .string("wait")])])]
    let node: JSONObject = ["id": .string("wait"), "nodeType": .string("command"), "model": .string(""),
      "command": .object(["executable": .string("/bin/sleep"), "arguments": .array([.string("20")])])]
    try JSONEncoder().encode(workflow).write(to: definitions.appendingPathComponent("workflow.json"))
    try JSONEncoder().encode(node).write(to: definitions.appendingPathComponent("nodes/wait.json"))
    let plan = try PrivateWorkflowPlan(config: ["workflowId": .string("slow"),
      "definitionRoot": .string(definitions.deletingLastPathComponent().path), "outputSchema": .object(schema)])
    let started = Date()
    do {
      _ = try await PrivateWorkflowWorker.executeWorkflow(.init(plan: plan, deadline: Date().addingTimeInterval(1.5),
        environment: [:], credentials: []), root: root.appendingPathComponent("guest"))
      XCTFail("slow inner graph completed")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .timeout)
    }
    XCTAssertLessThan(Date().timeIntervalSince(started), 15)
    XCTAssertEqual(PrivateWorkflowWorker.failure(for: WorkflowPublicationError.validationRejected("PRIVATE")),
      AdapterExecutionError(.invalidOutput, "private workflow execution failed"))
    XCTAssertEqual(PrivateWorkflowWorker.failure(for: AdapterExecutionError(.timeout, "PRIVATE")),
      AdapterExecutionError(.timeout, "private workflow execution failed"))
    XCTAssertEqual(PrivateWorkflowWorker.failure(for: CocoaError(.fileNoSuchFile)).code, .providerError)
  }

  func testGuestPrivilegeAndMountChecksRejectUnsafeBoundaries() throws {
    let status = "NoNewPrivs:\t1\nCapEff:\t0\nCapPrm:\t0\nCapBnd:\t0\nCapAmb:\t0\n"
    let mounts = "1 0 0:1 / / ro - ext4 disk rw\n2 1 0:2 / /tmp rw,nosuid,nodev,noexec - tmpfs tmpfs rw\n"
    try PrivateWorkflowWorker.verifyGuestMetadata(status: [status], mounts: mounts, temporaryBytes: 256 * 1024 * 1024)
    try PrivateWorkflowWorker.verifyGuestMetadata(status: [status], mounts: mounts,
      temporaryBytes: 1024 * 1024 * 1024, maximumTemporaryMiB: 1024)
    XCTAssertThrowsError(try PrivateWorkflowWorker.verifyGuestMetadata(status: [status], mounts: mounts,
      temporaryBytes: 1025 * 1024 * 1024, maximumTemporaryMiB: 1024))
    XCTAssertThrowsError(try PrivateWorkflowWorker.verifyGuestMetadata(status: [status], mounts: mounts,
      temporaryBytes: 1, maximumTemporaryMiB: 4097))
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
    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory:
      canonicalRuntimeStoreRoot(sessionStoreRoot: root.appendingPathComponent("guest/sessions").path))
    let snapshots = try store.loadAll()
    XCTAssertEqual(snapshots.count, 1)
    let database = try SQLiteDatabase.open(path: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root.appendingPathComponent("guest/sessions").path)),
      mode: .readOnly, options: .readOnlyDefault)
    XCTAssertFalse(try database.tableExists("cli_workflow_sessions"))
    XCTAssertEqual(snapshots.first?.session.status, .completed)
    XCTAssertTrue(try XCTUnwrap(String(data: JSONEncoder().encode(snapshots), encoding: .utf8)).contains("RAW_INTERMEDIATE_CANARY"))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("guest/artifacts").path), [])
    var command = WorkflowRunCommand()
    command.outputProjection = PrivateWorkflowWorker.rootResult
    let ordinary = await WorkflowRunCommand().runWithoutSpecialistMonitor(.init(target: "check",
      resolution: .init(workflowName: "check", workflowDefinitionDir: definitions.deletingLastPathComponent().path,
        workingDirectory: root.appendingPathComponent("ordinary").path), output: .json,
      sessionStore: root.appendingPathComponent("ordinary-sessions").path))
    XCTAssertEqual(ordinary.exitCode, .success)
    XCTAssertTrue(ordinary.stdout.contains("RAW_INTERMEDIATE_CANARY"))
    let ordinaryDatabase = try SQLiteDatabase.open(path: CLIWorkflowSessionStore.defaultDatabasePath(
      rootDirectory: root.appendingPathComponent("ordinary-sessions").path), mode: .readOnly, options: .readOnlyDefault)
    XCTAssertTrue(try ordinaryDatabase.tableExists("cli_workflow_sessions"))
    let projected = await command.runWithoutSpecialistMonitor(.init(target: "check",
      resolution: .init(workflowName: "check", workflowDefinitionDir: definitions.deletingLastPathComponent().path,
        workingDirectory: root.appendingPathComponent("projected").path), output: .json,
      sessionStore: root.appendingPathComponent("projected-sessions").path))
    XCTAssertEqual(projected.exitCode, .success)
    XCTAssertFalse(projected.stdout.contains("RAW_INTERMEDIATE_CANARY"))
    XCTAssertLessThan(projected.stdout.utf8.count, 1024)
  }

  /// CI also runs this exact graph in a network-denied 2 GiB container with
  /// a 1 GiB tmpfs. Ten copies previously killed the private worker (137).
  func testEmbeddedBulkGraphRetainsCanonicalHistoryWithoutCLIProjection() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("private-bulk")
    defer { try? FileManager.default.removeItem(at: root) }
    let definitions = root.appendingPathComponent("definitions/bulk")
    try FileManager.default.createDirectory(at: definitions, withIntermediateDirectories: true)
    let canary = "PRIVATE_BULK_CANARY"
    let bulk = canary + String(repeating: "x", count: 1024 * 1024)
    let identities = ["source"] + (0..<10).map { "copy-\($0)" } + ["done"]
    let nodes: [JSONValue] = [("source", ["large": JSONValue.string(bulk)]),
      ("copy", ["large": JSONValue.string("{{input.large}}")]),
      ("done", ["status": JSONValue.string("ok")])].map { id, payload in
        .object(["id": .string(id), "addon": .object(["name": .string("riela/json-compose"),
          "version": .string("1"), "config": .object(["payload": .object(payload)])])])
      }
    let steps: [JSONValue] = identities.enumerated().map { index, id in
      var step: JSONObject = ["id": .string(id), "nodeId": .string(id.hasPrefix("copy-") ? "copy" : id)]
      if index + 1 < identities.count {
        step["transitions"] = .array([.object(["toStepId": .string(identities[index + 1])])])
      }
      return .object(step)
    }
    try JSONEncoder().encode(["workflowId": JSONValue.string("bulk"), "description": .string("Synthetic bulk regression"),
      "defaults": .object(["nodeTimeoutMs": .integer(30000), "maxLoopIterations": .integer(1)]),
      "entryStepId": .string("source"), "nodes": .array(nodes), "steps": .array(steps)]).write(to: definitions.appendingPathComponent("workflow.json"))
    let plan = try PrivateWorkflowPlan(config: ["workflowId": .string("bulk"),
      "definitionRoot": .string(definitions.deletingLastPathComponent().path),
      "temporaryStorageMiB": .integer(1024), "outputSchema": .object(schema)])
    let guest = root.appendingPathComponent("guest")
    let output = try await PrivateWorkflowWorker.executeWorkflow(.init(plan: plan,
      deadline: Date().addingTimeInterval(150), environment: [:], credentials: []), root: guest)
    XCTAssertEqual(output.payload, ["status": .string("ok")])
    let bytes = try JSONEncoder().encode(output)
    XCTAssertLessThan(bytes.count, 1024)
    XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(canary))
    let canonical = canonicalRuntimeStoreRoot(sessionStoreRoot: guest.appendingPathComponent("sessions").path)
    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonical)
    let snapshots = try store.loadAll()
    XCTAssertEqual(snapshots.count, 1)
    let snapshot = try XCTUnwrap(snapshots.first)
    XCTAssertEqual(snapshot.session.status, .completed)
    XCTAssertEqual(snapshot.session.executions.count, identities.count)
    XCTAssertTrue(String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self).contains(canary))
    let database = try SQLiteDatabase.open(path: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(
      rootDirectory: canonical), mode: .readOnly, options: .readOnlyDefault)
    XCTAssertFalse(try database.tableExists("cli_workflow_sessions"))
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

  func testPrivateEntrySelectsDeclaredSubgraphWithoutAnotherWorkflow() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("private-entry")
    defer { try? FileManager.default.removeItem(at: root) }
    let definitions = root.appendingPathComponent("definitions/shared")
    try FileManager.default.createDirectory(at: definitions, withIntermediateDirectories: true)
    let workflow: JSONObject = ["workflowId": .string("shared"), "description": .string("Synthetic entry regression"),
      "defaults": .object(["nodeTimeoutMs": .integer(30000), "maxLoopIterations": .integer(1)]),
      "entryStepId": .string("public"),
      "nodes": .array(["public", "private"].map { id in
        var addon: JSONObject = ["name": .string("riela/json-compose"), "version": .string("1"),
          "config": .object(["payload": .object(["status": .string(id == "private" ? "ok" : "public")])])]
        if id == "public" {
          addon["env"] = .object(["TOKEN": .object(["fromEnv": .string("PRIVATE_TEST_UNUSED_CREDENTIAL"), "required": .bool(true)])])
        }
        return .object(["id": .string(id), "addon": .object(addon)])
      }), "steps": .array(["public", "private"].map { .object(["id": .string($0), "nodeId": .string($0)]) })]
    try JSONEncoder().encode(workflow).write(to: definitions.appendingPathComponent("workflow.json"))
    var config: JSONObject = ["workflowId": .string("shared"),
      "definitionRoot": .string(definitions.deletingLastPathComponent().path),
      "outputSchema": .object(schema), "entryStepId": .string("private")]
    let plan = try PrivateWorkflowPlan(config: config)
    let output = try await PrivateWorkflowWorker.executeWorkflow(.init(plan: plan,
      deadline: Date().addingTimeInterval(30), environment: [:], credentials: []), root: root.appendingPathComponent("guest"))
    XCTAssertEqual(output.payload, ["status": .string("ok")])
    let snapshots = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory:
      canonicalRuntimeStoreRoot(sessionStoreRoot: root.appendingPathComponent("guest/sessions").path)).loadAll()
    XCTAssertEqual(snapshots.first?.session.entryStepId, "private")
    // Reachable credentials remain mandatory; only the unselected island is
    // excluded. This does not weaken the actual node's environment binding.
    let ordinary = await WorkflowRunCommand().runWithoutSpecialistMonitor(.init(target: "shared",
      resolution: .init(workflowName: "shared", workflowDefinitionDir: definitions.deletingLastPathComponent().path,
        workingDirectory: root.path), output: .json, sessionStore: root.appendingPathComponent("ordinary").path))
    XCTAssertEqual(ordinary.exitCode, .failure)
    XCTAssertTrue(ordinary.stdout.contains("environment_required_missing"))
    let parsed = try RielaArgumentParser().parse(["workflow", "run", "shared", "--entry-step", "private",
      "--workflow-definition-dir", definitions.deletingLastPathComponent().path, "--working-dir", root.path,
      "--session-store", root.appendingPathComponent("selected-cli").path, "--output", "json"])
    guard case let .workflow(.run(selected)) = parsed else { return XCTFail("entry option was not parsed") }
    XCTAssertEqual(selected.entryStepId, "private")
    let selectedResult = await WorkflowRunCommand().runWithoutSpecialistMonitor(selected)
    XCTAssertEqual(selectedResult.exitCode, .success)
    let selectedPayload = try JSONDecoder().decode(JSONObject.self, from: Data(selectedResult.stdout.utf8))
    XCTAssertEqual(selectedPayload["rootOutput"], .object(["status": .string("ok")]))
    XCTAssertThrowsError(try RielaArgumentParser().parse(["workflow", "validate", "shared", "--entry-step", "private"]))
    for options in [WorkflowRunOptions(target: "shared", endpoint: "http://127.0.0.1:1", entryStepId: "private"),
      WorkflowRunOptions(target: "shared", resumeSessionId: "original-session", entryStepId: "private")] {
      let refusal = await WorkflowRunCommand().runWithoutSpecialistMonitor(options)
      XCTAssertEqual(refusal.exitCode, .usage)
    }
    for invalid in ["", "../private", "private/child"] {
      config["entryStepId"] = .string(invalid)
      XCTAssertThrowsError(try PrivateWorkflowPlan(config: config))
    }
    config["entryStepId"] = .string("absent")
    do {
      _ = try await PrivateWorkflowWorker.executeWorkflow(.init(plan: try .init(config: config),
        deadline: Date().addingTimeInterval(30), environment: [:], credentials: []), root: root.appendingPathComponent("missing"))
      XCTFail("undeclared private entry accepted")
    } catch { XCTAssertTrue(error is AdapterExecutionError) }
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

  func testConfiguredFailureStagesRejectUnknownLabelsAndFreeText() throws {
    var config: JSONObject = ["workflowId": .string("synthetic"), "outputSchema": .object(schema),
      "failureStages": .object(["collect": .string("acquisition")])]
    let plan = try PrivateWorkflowPlan(config: config)
    let message = PrivateWorkflowFailureDiagnostic(stage: "acquisition", kind: WorkflowSessionFailureKind.adapterFailure.rawValue).message
    XCTAssertEqual(PrivateWorkflowFailureDiagnostic.parse(message, plan: plan)?.stage, "acquisition")
    for rejected in [message + " PRIVATE_BODY_CANARY", message.replacingOccurrences(of: "acquisition", with: "unknown"),
                     message.replacingOccurrences(of: WorkflowSessionFailureKind.adapterFailure.rawValue, with: "PRIVATE_BODY_CANARY")] {
      XCTAssertNil(PrivateWorkflowFailureDiagnostic.parse(rejected, plan: plan))
    }
    config["failureStages"] = .object(["collect": .string("private message with spaces")])
    XCTAssertThrowsError(try PrivateWorkflowPlan(config: config))
    config["failureStages"] = .object(["../private": .string("collect")])
    XCTAssertThrowsError(try PrivateWorkflowPlan(config: config))
    let disabled = try PrivateWorkflowPlan(config: ["workflowId": .string("synthetic"), "outputSchema": .object(schema)])
    XCTAssertNil(PrivateWorkflowFailureDiagnostic.parse(message, plan: disabled))
  }

  func testHostOnlyExportsConfiguredStageAndFiniteFailureKind() async throws {
    for allowed in [false, true] {
      let root = try makeRielaCLITestTemporaryDirectory("private-public-failure")
      defer { try? FileManager.default.removeItem(at: root) }
      let diagnostic = PrivateWorkflowFailureDiagnostic(stage: allowed ? "acquisition" : "PRIVATE_BODY_CANARY",
        kind: WorkflowSessionFailureKind.adapterFailure.rawValue)
      let runner = PrivateWorkflowFixtureRunner(failure: .init(.providerError, diagnostic.message))
      var request = input()
      request.addon.config?["failureStages"] = .object(["collect": .string("acquisition")])
      let events = PrivateWorkflowEventRecorder()
      do {
        _ = try await host(runner, root: root).execute(request,
          context: .init(backendEventHandler: { await events.append($0) }))
        XCTFail("failed guest returned success")
      } catch let error as AdapterExecutionError {
        XCTAssertEqual(error.code, .providerError)
        XCTAssertEqual(error.message, allowed ? diagnostic.message : "private workflow execution failed")
        XCTAssertFalse(error.message.contains("PRIVATE_BODY_CANARY"))
      }
      let recorded = await events.events
      XCTAssertEqual(recorded.count, allowed ? 1 : 0)
      if allowed {
        XCTAssertEqual(recorded.first?.eventType, "private-workflow-failure")
        XCTAssertEqual(recorded.first?.metadata, ["stage": .string("acquisition"),
          "kind": .string(WorkflowSessionFailureKind.adapterFailure.rawValue)])
      }
    }
  }

  func testEmbeddedFailureMapsTrustedStepWithoutExportingCommandStderr() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("private-inner-diagnostic")
    defer { try? FileManager.default.removeItem(at: root) }
    let definitions = root.appendingPathComponent("definitions/failing")
    try FileManager.default.createDirectory(at: definitions, withIntermediateDirectories: true)
    let workflow: JSONObject = ["workflowId": .string("failing"), "entryStepId": .string("read"),
      "defaults": .object(["nodeTimeoutMs": .integer(30000), "maxLoopIterations": .integer(1)]),
      "nodes": .array([.object(["id": .string("read"), "nodeFile": .string("node.json")])]),
      "steps": .array([.object(["id": .string("read"), "nodeId": .string("read"), "role": .string("worker")])])]
    let node: JSONObject = ["id": .string("read"), "nodeType": .string("command"), "variables": .object([:]),
      "command": .object(["executable": .string("/bin/sh"), "arguments": .array([.string("-c"),
        .string("printf PRIVATE_BODY_CANARY >&2; exit 7")])])]
    try JSONEncoder().encode(workflow).write(to: definitions.appendingPathComponent("workflow.json"))
    try JSONEncoder().encode(node).write(to: definitions.appendingPathComponent("node.json"))
    let plan = try PrivateWorkflowPlan(config: ["workflowId": .string("failing"),
      "definitionRoot": .string(definitions.deletingLastPathComponent().path), "outputSchema": .object(schema),
      "failureStages": .object(["read": .string("acquisition")])])
    do {
      _ = try await PrivateWorkflowWorker.executeWorkflow(.init(plan: plan, deadline: Date().addingTimeInterval(20),
        environment: [:], credentials: []), root: root.appendingPathComponent("guest"))
      XCTFail("command unexpectedly succeeded")
    } catch {
      let exported = PrivateWorkflowWorker.failure(for: error)
      XCTAssertEqual(PrivateWorkflowFailureDiagnostic.parse(exported.message, plan: plan)?.stage, "acquisition")
      XCTAssertFalse(exported.message.contains("PRIVATE_BODY_CANARY"))
      XCTAssertFalse(exported.message.contains(root.path))
    }
  }

  func testPublicUserCacheSeedsAndDeltasSurviveRejectedPrivateResults() async throws {
    for invalid in [false, true] {
      let root = try makeRielaCLITestTemporaryDirectory("private-user-cache-host")
      defer { try? FileManager.default.removeItem(at: root) }
      let environment = ["RIELA_CACHE_ROOT": root.appendingPathComponent("cache").path]
      let cache = XUserPrivateCacheSpace(environment: environment)
      XCTAssertEqual(cache.consume(.array([.object(["id": .string("1"), "username": .string("first")])])), "stored")
      let line = try XCTUnwrap(PrivateWorkflowCacheTransport.line(cache: "x-gateway-users", payload:
        .array([.object(["id": .string("2"), "username": .string("second")])])))
      let runner = PrivateWorkflowFixtureRunner(invalidPayload: invalid, usageLine: line)
      var controller = host(runner, root: root)
      controller.environment.merge(environment) { _, new in new }
      var request = input(); request.addon.config?["cacheSpaces"] = .array([.string("x-gateway-users")])
      let events = PrivateWorkflowEventRecorder()
      do {
        _ = try await controller.execute(request, context: .init(backendEventHandler: { await events.append($0) }))
        XCTAssertFalse(invalid)
      } catch { XCTAssertTrue(invalid) }
      let calls = await runner.calls
      let stdin = try XCTUnwrap(calls.first { $0.0.arguments.contains("exec") }?.1)
      let captured = try JSONDecoder().decode(PrivateWorkflowRequest.self, from: Data(stdin.utf8))
      let seed = try JSONValue.object(try XCTUnwrap(captured.cacheSeeds?["x-gateway-users"])).compactJSONString()
      XCTAssertTrue(seed.contains("first"));XCTAssertFalse(seed.contains("second"))
      let after = try JSONValue.object(cache.snapshot() ?? [:]).compactJSONString()
      XCTAssertTrue(after.contains("first"));XCTAssertTrue(after.contains("second"))
      for (configuration, _) in calls {
        XCTAssertFalse(configuration.arguments.joined().contains("first"))
        XCTAssertFalse(configuration.environment.values.contains { $0.contains("first") })
      }
      let recorded = await events.events
      XCTAssertEqual(recorded.filter { $0.eventType == "private-cache-exchange" }.count, 1)
      XCTAssertFalse(String(describing: recorded).contains("second"))
    }
  }

  func testUnregisteredOrDuplicateCacheSpacesRefuseBeforeLaunch() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("private-cache-config")
    defer { try? FileManager.default.removeItem(at: root) }
    for names in [["article-bodies"], ["x-gateway-users", "x-gateway-users"]] {
      let runner = PrivateWorkflowFixtureRunner()
      var request = input();request.addon.config?["cacheSpaces"] = .array(names.map(JSONValue.string))
      do { _ = try await host(runner, root: root).execute(request, context: .init());XCTFail("invalid cache configuration accepted") }
      catch { XCTAssertTrue(error is AdapterExecutionError) }
      let calls = await runner.calls;XCTAssertTrue(calls.isEmpty)
    }
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
    #if os(Linux)
    // On Linux the test bundle URL is already the products directory, unlike
    // Darwin's .xctest bundle. Resolve from the actual test executable instead.
    let worker = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
      .deletingLastPathComponent().appendingPathComponent("riela").path
    #else
    let worker = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
      .appendingPathComponent("riela").resolvingSymlinksInPath().path
    #endif
    return .init(environment: ["RIELA_CONTAINER_RUNTIME": "docker", "RIELA_SANDBOX_WORKER_EXECUTABLE": worker,
      "SOURCE_SECRET": "SYNTHETIC_SECRET_TOKEN", "MODEL_SECRET": "SYNTHETIC_SECRET_FILE"],
      workingDirectory: root, runner: runner, directoryParent: root)
  }
}

private actor PrivateWorkflowEventRecorder {
  var events: [AdapterBackendEvent] = []
  func append(_ event: AdapterBackendEvent) { events.append(event) }
}

private actor PrivateWorkflowFixtureRunner: LocalProcessRunning {
  var calls: [(LocalProcessConfiguration, String)] = []
  var cancel: Bool
  var invalidPayload: Bool
  var event: Bool
  var usageLine: String?
  var when: [String: Bool]
  var model: String
  var provider: String
  var status: Int32
  var recordVersion: Int
  var failure: AdapterExecutionError?
  init(cancel: Bool = false, invalidPayload: Bool = false, event: Bool = false, usageLine: String? = nil,
       when: [String: Bool] = ["always": true], model: String = "fixture", provider: String = "fixture",
       status: Int32 = 0, recordVersion: Int = SandboxNodeRecord.currentVersion, failure: AdapterExecutionError? = nil) {
    self.cancel = cancel; self.invalidPayload = invalidPayload; self.event = event
    self.usageLine = usageLine; self.when = when; self.model = model; self.provider = provider
    self.status = status; self.recordVersion = recordVersion; self.failure = failure
  }
  func run(configuration: LocalProcessConfiguration, stdin: String, deadline: Date?) async throws -> LocalProcessResult {
    calls.append((configuration, stdin))
    guard configuration.arguments.contains("exec") else { return .init(stdout: "", stderr: "", terminationStatus: 0) }
    if cancel { throw CancellationError() }
    let output = AdapterExecutionOutput(provider: provider, model: model, promptText: "", completionPassed: true, when: when,
      payload: invalidPayload ? ["raw": .string("RAW_UNAPPROVED")] : ["status": .string("ok")])
    var record = SandboxNodeRecord(kind: event ? .event : .result, output: event ? nil : output)
    if let failure { record = .init(kind: .failure, failure: .init(failure)) }
    record.version = recordVersion
    let stdout = try XCTUnwrap(String(data: JSONEncoder().encode(record), encoding: .utf8))
    return .init(stdout: stdout + "\n", stderr: usageLine.map { $0 + "\n" } ?? "", terminationStatus: status)
  }
}
