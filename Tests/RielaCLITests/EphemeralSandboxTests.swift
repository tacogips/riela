import Foundation
import RielaAdapters
import RielaCore
import XCTest
@testable import RielaCLI

final class EphemeralSandboxTests: XCTestCase {
  func testNativeStructuredSchemaIsAnExplicitWorkerCapability() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("native-schema-protocol")
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = EphemeralFixtureRunner()
    let adapter = SandboxingNodeAdapter(primary: EphemeralForbiddenHost(), environment: [
      "RIELA_SANDBOX_WORKER_EXECUTABLE": workerPath, "RIELA_CONTAINER_RUNTIME": "docker"
    ], workingDirectory: root.path, runner: runner, directoryParent: root)
    let sandbox = WorkflowExecutionSandbox(backend: .container, networkPolicy: .denied,
      container: .init(image: "fixture:local"), ephemeralHome: true)
    _ = try await adapter.execute(.init(node: .init(id: "inspect", executionBackend: .codexAgent,
      model: "fixture", sandbox: sandbox, output: .init(jsonSchema: ["type": .string("object")],
        nativeStructuredOutput: true)), promptText: "synthetic"), context: .init())
    let calls = await runner.calls
    let request = try JSONDecoder().decode(SandboxNodeRequest.self, from: Data(try XCTUnwrap(calls[1].1).utf8))
    XCTAssertEqual(request.version, SandboxNodeRequest.currentVersion)
    XCTAssertEqual(request.capabilities, [.validationRejection, .ephemeralHome, .nativeStructuredOutput])
    XCTAssertEqual(request.input.node.output?.nativeStructuredOutput, true)
  }

  func testActualContainerKeepsCredentialsAndModelStateInGuestTmpfs() async throws {
    let image = ProcessInfo.processInfo.environment["RIELA_EPHEMERAL_CONTAINER_IMAGE"]
    try XCTSkipUnless(image != nil, "opt-in native worker image required")
    let root = try makeRielaCLITestTemporaryDirectory("ephemeral-container")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = root.appendingPathComponent("tools")
    try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: false)
    let sentinel = root.appendingPathComponent("unshared-host")
    try "host-sentinel".write(to: sentinel, atomically: true, encoding: .utf8)
    let fixture = tools.appendingPathComponent("codex-fixture")
    let message = JSONValue.object(["type": .string("item.completed"), "item": .object([
      "type": .string("agent_message"), "text": .string(#"{"text":"isolated ephemeral fixture"}"#)])])
    let event = String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
    try """
    #!/bin/sh
    set -eu
    if [ "${1:-}" = --version ]; then echo codex-fixture; exit 0; fi
    case "$HOME" in /tmp/riela-private-*/home) ;; *) exit 10 ;; esac
    [ "$(cat "$HOME/.vendor/auth.json")" = synthetic-private-credential ]
    [ ! -e "$FIXTURE_HOST_SENTINEL" ]
    grep -q ' /tmp tmpfs ' /proc/mounts
    printf 'guest-refresh' > "$HOME/.vendor/auth.json"
    cat >/dev/null
    printf '%s\\n' \
      '{"type":"thread.started","thread_id":"ephemeral-fixture"}' \
      '\(event)' \
      '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
    """.write(to: fixture, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.path)
    let adapter = SandboxingNodeAdapter(primary: EphemeralForbiddenHost(), environment: [
      "RIELA_SANDBOX_WORKER_EXECUTABLE": workerPath, "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
      "VENDOR_AUTH_JSON": "synthetic-private-credential"
    ], workingDirectory: root.path, directoryParent: root)
    let options = WorkflowExecutionSandbox(backend: .container, readPaths: [tools.path],
      container: .init(image: image!, runtime: .appleContainer), ephemeralHome: true,
      credentialEnvironment: ["VENDOR_AUTH_JSON": ".vendor/auth.json"])
    let output = try await adapter.execute(.init(node: .init(id: "edit", executionBackend: .codexAgent,
      model: "fixture", sandbox: options, agentSandbox: .readOnly,
      variables: ["codexExecutable": .string(fixture.path)], output: .init(jsonSchema: ["type": .string("object")])), promptText: "synthetic public input",
      agentEnvironment: ["FIXTURE_HOST_SENTINEL": sentinel.path]), context: .init(deadline: Date().addingTimeInterval(120)))
    XCTAssertEqual(output.payload["text"], .string("isolated ephemeral fixture"))
    XCTAssertEqual(output.promptText, "")
    XCTAssertEqual(output.usage?.providerRaw, [:])
    XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "host-sentinel")
    XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["tools", "unshared-host"])
  }

  func testCredentialsTravelOnlyOnWorkerStdinWithoutWritableHostShares() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("ephemeral-sandbox")
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = EphemeralFixtureRunner()
    let adapter = SandboxingNodeAdapter(primary: EphemeralForbiddenHost(), environment: [
      "RIELA_SANDBOX_WORKER_EXECUTABLE": workerPath, "RIELA_CONTAINER_RUNTIME": "docker",
      "VENDOR_AUTH_JSON": "synthetic-private-credential", "UNSELECTED_SECRET": "must-not-forward"
    ], workingDirectory: root.path, runner: runner, directoryParent: root)
    let sandbox = WorkflowExecutionSandbox(backend: .container, networkPolicy: .egressAllowed,
      container: .init(image: "fixture:local"), ephemeralHome: true,
      credentialEnvironment: ["VENDOR_AUTH_JSON": ".vendor/auth.json"])
    let output = try await adapter.execute(.init(node: .init(id: "edit", executionBackend: .codexAgent,
      model: "fixture", sandbox: sandbox, output: .init(jsonSchema: ["type": .string("object")])), promptText: "inspected input"), context: .init())
    XCTAssertEqual(output.payload["status"], .string("ok"))
    let calls = await runner.calls
    XCTAssertEqual(calls.count, 3)
    let initialize = calls[0]
    let call = calls[1]
    XCTAssertFalse(call.0.arguments.joined().contains("synthetic-private-credential"))
    XCTAssertFalse(call.0.environment.values.contains("synthetic-private-credential"))
    XCTAssertEqual(initialize.1, "")
    XCTAssertTrue(initialize.0.arguments.contains("--read-only"))
    XCTAssertTrue(initialize.0.arguments.contains("--log-driver"))
    XCTAssertTrue(call.0.arguments.contains("exec"))
    XCTAssertTrue(calls[2].0.arguments.contains("--force"))
    XCTAssertFalse(call.0.arguments.contains("-v"))
    XCTAssertFalse(call.0.arguments.contains("--mount"))
    let request = try JSONDecoder().decode(SandboxNodeRequest.self, from: Data(try XCTUnwrap(call.1).utf8))
    XCTAssertEqual(request.version, SandboxNodeRequest.currentVersion)
    XCTAssertEqual(request.capabilities, [.validationRejection, .ephemeralHome])
    XCTAssertEqual(request.credentials?.count, 1)
    XCTAssertEqual(request.credentials?.first?.homePath, ".vendor/auth.json")
    XCTAssertEqual(request.credentials?.first?.value, "synthetic-private-credential")
    XCTAssertEqual(request.input.node.workingDirectory, "/tmp")
    XCTAssertFalse(try XCTUnwrap(call.1).contains("must-not-forward"))
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty,
      "ephemeral invocation must leave no host files or credential projection")
  }

  func testEphemeralPolicyRejectsUnsafeCredentialTargetsAndWritableShares() throws {
    let invalid: [WorkflowExecutionSandbox] = [
      .init(backend: .seatbelt, ephemeralHome: true),
      .init(backend: .container, writePaths: ["/host/work"], ephemeralHome: true),
      .init(backend: .container, container: .init(mounts: [.init(source: "/host/work", target: "/work", readOnly: false)]), ephemeralHome: true),
      .init(backend: .container, credentialEnvironment: ["AUTH": ".vendor/auth"]),
      .init(backend: .container, environment: ["AUTH"], ephemeralHome: true, credentialEnvironment: ["AUTH": ".vendor/auth"]),
      .init(backend: .container, ephemeralHome: true, credentialEnvironment: ["AUTH": "../escape"]),
      .init(backend: .container, ephemeralHome: true, credentialEnvironment: ["AUTH": ".vendor", "SECOND": ".vendor/auth"])
    ]
    for options in invalid { XCTAssertThrowsError(try options.validate()) }
    let valid = WorkflowExecutionSandbox(backend: .container, ephemeralHome: true,
      credentialEnvironment: ["AUTH": ".vendor/auth"])
    XCTAssertEqual(try JSONDecoder().decode(WorkflowExecutionSandbox.self, from: JSONEncoder().encode(valid)), valid)
  }

  func testMissingCredentialAndSessionReuseFailBeforeStartingContainer() async throws {
    let runner = EphemeralFixtureRunner()
    let adapter = SandboxingNodeAdapter(primary: EphemeralForbiddenHost(),
      environment: ["RIELA_SANDBOX_WORKER_EXECUTABLE": workerPath], workingDirectory: nil, runner: runner)
    let options = WorkflowExecutionSandbox(backend: .container, ephemeralHome: true, credentialEnvironment: ["AUTH": ".vendor/auth"])
    for policy: WorkflowStepSessionPolicy? in [nil, .init(mode: .reuse)] {
      do {
        _ = try await adapter.execute(.init(node: .init(id: "edit", executionBackend: .codexAgent, model: "fixture", sandbox: options, output: .init(jsonSchema: ["type": .string("object")])),
          promptText: "fixture", sessionPolicy: policy), context: .init())
        XCTFail("Unavailable credential or session reuse must not start a container")
      } catch { XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked) }
    }
    let calls = await runner.calls
    XCTAssertTrue(calls.isEmpty)
  }

  func testCancelledWorkerStillRemovesOnlyItsOwnedContainer() async throws {
    let runner = EphemeralFixtureRunner(failExec: true)
    let root = try makeRielaCLITestTemporaryDirectory("ephemeral-cancel")
    defer { try? FileManager.default.removeItem(at: root) }
    let adapter = SandboxingNodeAdapter(primary: EphemeralForbiddenHost(), environment: [
      "RIELA_SANDBOX_WORKER_EXECUTABLE": workerPath, "RIELA_CONTAINER_RUNTIME": "docker"
    ], workingDirectory: root.path, runner: runner, directoryParent: root)
    do {
      _ = try await adapter.execute(.init(node: .init(id: "edit", executionBackend: .codexAgent,
        model: "fixture", sandbox: .init(backend: .container, ephemeralHome: true), output: .init(jsonSchema: ["type": .string("object")])), promptText: "fixture"), context: .init())
      XCTFail("cancelled worker must fail")
    } catch { XCTAssertTrue(error is CancellationError) }
    let calls = await runner.calls
    XCTAssertEqual(calls.count, 3)
    let initialize = calls[0].0.arguments
    let name = initialize[try XCTUnwrap(initialize.firstIndex(of: "--name")) + 1]
    XCTAssertTrue(name.hasPrefix("riela-agent-"))
    XCTAssertEqual(calls[2].0.arguments.suffix(3), ["rm", "--force", name])
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
  }

  func testAdmissionRemainsHeldThroughOwnedContainerCancellationCleanup() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("ephemeral-admission-cleanup")
    defer { try? FileManager.default.removeItem(at: root) }
    let pool = root.appendingPathComponent("pool")
    let runner = EphemeralFixtureRunner(failExec: true, pool: pool)
    let adapter = SandboxingNodeAdapter(primary: EphemeralForbiddenHost(), environment: [
      "RIELA_SANDBOX_WORKER_EXECUTABLE": workerPath, "RIELA_CONTAINER_RUNTIME": "docker", "TEST_POOL": pool.path
    ], workingDirectory: root.path, runner: runner, directoryParent: root)
    let policy = WorkflowExecutionAdmission(directoryEnvironment: "TEST_POOL", capacity: 1)
    do {
      _ = try await adapter.execute(.init(node: .init(id: "inspect", executionBackend: .codexAgent, model: "fixture",
        sandbox: .init(backend: .container, ephemeralHome: true, admission: policy),
        output: .init(jsonSchema: ["type": .string("object")])), promptText: "synthetic"), context: .init())
      XCTFail("must cancel")
    } catch { XCTAssertTrue(error is CancellationError) }
    let observations = await runner.heldObservations
    XCTAssertEqual(observations, 3, "lease must cover create, exec and rm")
    let lease = try await SandboxExecutionAdmission.acquire(policy, environment: ["TEST_POOL": pool.path],
      deadline: Date().addingTimeInterval(1))
    XCTAssertNotNil(lease)
    withExtendedLifetime(lease) {}
  }

  func testAdmissionRejectsInsufficientExecutionTimeBeforeStartingContainer() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("ephemeral-admission-reserve")
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = EphemeralFixtureRunner()
    // Static checks (worker executable included) run first; the startup reserve is the only refusal left.
    let adapter = SandboxingNodeAdapter(primary: EphemeralForbiddenHost(), environment: ["TEST_POOL": root.path,
      "RIELA_SANDBOX_WORKER_EXECUTABLE": workerPath, "RIELA_CONTAINER_RUNTIME": "docker"],
      workingDirectory: root.path, runner: runner, directoryParent: root)
    let policy = WorkflowExecutionAdmission(directoryEnvironment: "TEST_POOL", capacity: 4, minimumRemainingSeconds: 2)
    do {
      _ = try await adapter.execute(.init(node: .init(id: "inspect", executionBackend: .codexAgent, model: "fixture",
        sandbox: .init(backend: .container, ephemeralHome: true, admission: policy),
        output: .init(jsonSchema: ["type": .string("object")])), promptText: "synthetic"),
        context: .init(deadline: Date().addingTimeInterval(0.2)))
      XCTFail("insufficient startup budget must not launch a container")
    } catch { XCTAssertEqual((error as? AdapterExecutionError)?.code, .timeout) }
    let calls = await runner.calls
    XCTAssertTrue(calls.isEmpty)
  }

  // MARK: - Validation retry through the isolated worker protocol (review C/B1)

  func testEphemeralContractRejectionUsesRunnerValidationRetry() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("ephemeral-validation-retry")
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = EphemeralFixtureRunner(workerRecords: [
      [.init(kind: .rejected, rejection: SandboxNodeWorker.privateRejectionMessage)],
      [Self.resultRecord(["status": .string("ok")])]
    ])
    let result = try await runSandboxedWorkflow(adapter: dockerAdapter(runner, root: root),
      sandbox: .init(backend: .container, container: .init(image: "fixture:local"), ephemeralHome: true),
      output: .init(jsonSchema: Self.statusSchema))
    let workerCalls = await runner.workerCalls
    XCTAssertEqual(workerCalls, 2, "undeclared maxValidationAttempts must default to 2 for sandboxed nodes")
    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.rootOutput?["status"], .string("ok"))
    XCTAssertEqual(result.session.executions.map(\.status), [.failed, .completed])
    XCTAssertEqual(result.session.executions.first?.failureReason, SandboxNodeWorker.privateRejectionMessage)
  }

  func testNonEphemeralParseRejectionKeepsReasonAndRetries() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("sandbox-validation-retry")
    defer { try? FileManager.default.removeItem(at: root) }
    let reason = "codex-agent output must be a JSON object"
    let runner = EphemeralFixtureRunner(workerRecords: [
      [.init(kind: .rejected, rejection: reason)], [Self.resultRecord(["status": .string("ok")])]
    ])
    let result = try await runSandboxedWorkflow(adapter: dockerAdapter(runner, root: root),
      sandbox: .init(backend: .container, container: .init(image: "fixture:local")),
      output: .init(jsonSchema: Self.statusSchema))
    let workerCalls = await runner.workerCalls
    XCTAssertEqual(workerCalls, 2)
    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.session.executions.first?.failureReason, reason)
  }

  func testExhaustedSandboxRejectionFailsAsAdapterFailure() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("sandbox-validation-exhausted")
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = EphemeralFixtureRunner(workerRecords: [[.init(kind: .rejected, rejection: "not JSON")]])
    do {
      _ = try await runSandboxedWorkflow(adapter: dockerAdapter(runner, root: root),
        sandbox: .init(backend: .container, container: .init(image: "fixture:local")),
        output: .init(jsonSchema: Self.statusSchema, maxValidationAttempts: 3))
      XCTFail("exhausted validation attempts must fail the run")
    } catch let error as WorkflowPublicationError {
      // Same terminal error as the in-process gateway path (classified adapterFailure by the runner).
      XCTAssertEqual(error, .validationRejected("not JSON"))
    }
    let workerCalls = await runner.workerCalls
    XCTAssertEqual(workerCalls, 3)
  }

  func testWorkerMapsValidationRejectionToFiniteRetryableRecord() throws {
    let rejection = WorkflowPublicationError.validationRejected("PRIVATE MODEL ANSWER is not JSON")
    let ephemeral = SandboxNodeWorker.terminalRecord(for: rejection, ephemeral: true, vendorSessionId: "vendor")
    XCTAssertEqual(ephemeral.kind, .rejected)
    XCTAssertEqual(ephemeral.rejection, SandboxNodeWorker.privateRejectionMessage)
    XCTAssertNil(ephemeral.vendorSessionId)
    let host = SandboxNodeWorker.terminalRecord(for: rejection, ephemeral: false, vendorSessionId: "vendor")
    XCTAssertEqual(host.kind, .rejected)
    XCTAssertEqual(host.rejection, "PRIVATE MODEL ANSWER is not JSON")
    XCTAssertEqual(host.vendorSessionId, "vendor")
    let long = SandboxNodeWorker.terminalRecord(for: WorkflowPublicationError.validationRejected(
      String(repeating: "é", count: 10_000)), ephemeral: false, vendorSessionId: nil)
    XCTAssertLessThanOrEqual(try XCTUnwrap(long.rejection).utf8.count, SandboxNodeRecord.maximumRejectionBytes)
    let failure = SandboxNodeWorker.terminalRecord(for: AdapterExecutionError(.timeout, "slow"),
      ephemeral: false, vendorSessionId: nil)
    XCTAssertEqual(failure.kind, .failure)
    XCTAssertEqual(failure.failure?.code, .timeout)
    XCTAssertEqual(SandboxNodeWorker.terminalRecord(for: CancellationError(), ephemeral: false, vendorSessionId: nil)
      .failure?.message, "isolated node worker execution failed")
  }

  func testHostRejectsMalformedOrForeignRejectionRecords() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("sandbox-rejection-records")
    defer { try? FileManager.default.removeItem(at: root) }
    // A private guest may only send the fixed text; any rejection needs a reason.
    for (ephemeral, record) in [(true, SandboxNodeRecord(kind: .rejected, rejection: "PRIVATE SOURCE TEXT")),
                                (false, SandboxNodeRecord(kind: .rejected)),
                                (false, SandboxNodeRecord(kind: .rejected, output: Self.resultRecord([:]).output,
                                  rejection: "x"))] {
      let runner = EphemeralFixtureRunner(workerRecords: [[record]])
      do {
        _ = try await dockerAdapter(runner, root: root).execute(.init(node: .init(id: "inspect", executionBackend: .codexAgent,
          model: "fixture", sandbox: .init(backend: .container, container: .init(image: "fixture:local"), ephemeralHome: ephemeral),
          output: .init(jsonSchema: Self.statusSchema)), promptText: "synthetic"), context: .init())
        XCTFail("malformed rejection accepted")
      } catch let error as AdapterExecutionError {
        XCTAssertEqual(error, AdapterExecutionError(.invalidOutput, "isolated node returned invalid worker records"))
      }
    }
  }

  func testHostRefusesRecordsFromOlderWorkerProtocol() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("sandbox-old-records")
    defer { try? FileManager.default.removeItem(at: root) }
    var old = Self.resultRecord(["status": .string("ok")])
    old.version = 1
    let runner = EphemeralFixtureRunner(workerRecords: [[old]])
    do {
      _ = try await dockerAdapter(runner, root: root).execute(.init(node: .init(id: "inspect", executionBackend: .codexAgent,
        model: "fixture", sandbox: .init(backend: .container, container: .init(image: "fixture:local")),
        output: .init(jsonSchema: Self.statusSchema)), promptText: "synthetic"), context: .init())
      XCTFail("old worker record accepted")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertTrue(error.message.contains("older record protocol"))
    }
  }

  func testRealWorkerRefusesOldProtocolWithRecordOldHostsDecode() throws {
    for (version, capabilities, expectedVersion, code) in [
      (3, nil, 1, AdapterExecutionErrorCode.policyBlocked),
      (SandboxNodeRequest.currentVersion, Set<SandboxNodeCapability>([.validationRejection, .ephemeralHome]),
        SandboxNodeRecord.currentVersion, .invalidInput)
    ] {
      let request = SandboxNodeRequest(version: version, capabilities: capabilities,
        input: .init(node: .init(id: "inspect", executionBackend: .codexAgent, model: "fixture"), promptText: "synthetic"),
        supervisorMode: false)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: workerPath)
      process.arguments = [SandboxNodeWorker.command]
      let input = Pipe(), output = Pipe()
      process.standardInput = input
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice
      try process.run()
      input.fileHandleForWriting.write(try JSONEncoder().encode(request) + Data([10]))
      try input.fileHandleForWriting.close()
      let stdout = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      let lines = stdout.split(separator: 10)
      XCTAssertEqual(lines.count, 1)
      let record = try JSONDecoder().decode(SandboxNodeRecord.self, from: Data(try XCTUnwrap(lines.first)))
      XCTAssertEqual(record.version, expectedVersion)
      XCTAssertEqual(record.kind, .failure)
      XCTAssertEqual(record.failure?.code, code)
    }
  }

  // MARK: - Private boundary metadata (review C/B2)

  func testEphemeralHostRejectsUnboundedRoutingAndMetadata() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("ephemeral-when-bound")
    defer { try? FileManager.default.removeItem(at: root) }
    var labels = Self.resultRecord(["status": .string("ok")])
    labels.output?.when = ["PRIVATE SOURCE SENTENCE": true]
    var model = Self.resultRecord(["status": .string("ok")])
    model.output?.model = "model with PRIVATE text"
    var prompt = Self.resultRecord(["status": .string("ok")])
    prompt.output?.promptText = "PRIVATE PROMPT"
    for record in [labels, model, prompt] {
      let runner = EphemeralFixtureRunner(workerRecords: [[record]])
      do {
        _ = try await dockerAdapter(runner, root: root).execute(.init(node: .init(id: "inspect", executionBackend: .codexAgent,
          model: "fixture", sandbox: .init(backend: .container, container: .init(image: "fixture:local"), ephemeralHome: true),
          output: .init(jsonSchema: Self.statusSchema)), promptText: "synthetic"), context: .init())
        XCTFail("unbounded private metadata accepted")
      } catch let error as AdapterExecutionError {
        XCTAssertEqual(error.code, .invalidOutput)
        XCTAssertFalse(error.message.contains("PRIVATE"))
      }
    }
  }

  // MARK: - Exit mapping, admission order and session boundary (review C/B5, B6, C)

  func testNonZeroWorkerExitUsesSharedMapping() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("sandbox-exit-mapping")
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = EphemeralFixtureRunner(workerStatus: 137)
    do {
      _ = try await dockerAdapter(runner, root: root).execute(.init(node: .init(id: "inspect", executionBackend: .codexAgent,
        model: "fixture", sandbox: .init(backend: .container, container: .init(image: "fixture:local")),
        output: .init(jsonSchema: Self.statusSchema)), promptText: "synthetic"), context: .init())
      XCTFail("non-zero worker exit accepted")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error, AdapterExecutionError(.providerError, "selected sandbox worker exited with status 137"))
    }
    let past = Date().addingTimeInterval(-1)
    XCTAssertEqual(isolatedWorkerExitError(status: 137, deadline: past, subject: "worker").code, .timeout)
    XCTAssertEqual(isolatedWorkerExitError(status: 112, deadline: nil, subject: "worker").code, .providerError)
    XCTAssertEqual(isolatedWorkerExitError(status: 112, deadline: past, subject: "worker", recognizesGuestRefusal: true),
      AdapterExecutionError(.policyBlocked, "private worker refused the guest identity or resource limits"))
  }

  func testStaticRefusalsDoNotWaitForBusyAdmissionPool() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("sandbox-admission-order")
    defer { try? FileManager.default.removeItem(at: root) }
    let pool = root.appendingPathComponent("pool")
    let policy = WorkflowExecutionAdmission(directoryEnvironment: "TEST_POOL", capacity: 1)
    let held = try await SandboxExecutionAdmission.acquire(policy, environment: ["TEST_POOL": pool.path], deadline: nil)
    defer { withExtendedLifetime(held) {} }
    let runner = EphemeralFixtureRunner()
    let adapter = SandboxingNodeAdapter(primary: EphemeralForbiddenHost(), environment: [
      "RIELA_SANDBOX_WORKER_EXECUTABLE": workerPath, "RIELA_CONTAINER_RUNTIME": "docker", "TEST_POOL": pool.path
    ], workingDirectory: root.path, runner: runner, directoryParent: root)
    let started = Date()
    // Missing schema and vendor-session reuse are both static ephemeral refusals.
    for (output, session) in [(NodeOutputContract?.none, WorkflowStepSessionPolicy?.none),
                              (NodeOutputContract(jsonSchema: Self.statusSchema), WorkflowStepSessionPolicy(mode: .reuse))] {
      do {
        _ = try await adapter.execute(.init(node: .init(id: "inspect", executionBackend: .codexAgent, model: "fixture",
          sandbox: .init(backend: .container, ephemeralHome: true, admission: policy), output: output), promptText: "synthetic",
          sessionPolicy: session), context: .init(deadline: Date().addingTimeInterval(5)))
        XCTFail("statically invalid node must not run")
      } catch let error as AdapterExecutionError { XCTAssertEqual(error.code, .policyBlocked) }
    }
    XCTAssertLessThan(Date().timeIntervalSince(started), 2, "static refusals must not wait for a pool slot")
    let calls = await runner.calls
    XCTAssertTrue(calls.isEmpty)
  }

  func testSessionReuseIgnoresAdmissionTuning() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("sandbox-session-admission")
    defer { try? FileManager.default.removeItem(at: root) }
    var first = Self.resultRecord(["status": .string("ok")])
    first.vendorSessionId = "vendor-session"
    let runner = EphemeralFixtureRunner(workerRecords: [[first], [Self.resultRecord(["status": .string("ok")])]])
    let adapter = SandboxingNodeAdapter(primary: EphemeralForbiddenHost(), environment: [
      "RIELA_SANDBOX_WORKER_EXECUTABLE": workerPath, "RIELA_CONTAINER_RUNTIME": "docker",
      "TEST_POOL": root.appendingPathComponent("pool").path, "TEST_POOL_B": root.appendingPathComponent("pool-b").path
    ], workingDirectory: root.path, runner: runner, directoryParent: root)
    let identity = AdapterExecutionIdentity(workflowRunId: "run", workflowSessionId: "session", stepId: "first")
    for (capacity, step, policy) in [(1, "first", WorkflowStepSessionPolicy?.none),
                                     (2, "second", WorkflowStepSessionPolicy(mode: .reuse, inheritFromStepId: "first"))] {
      var stepIdentity = identity
      stepIdentity.stepId = step
      _ = try await adapter.execute(.init(node: .init(id: step, executionBackend: .codexAgent, model: "fixture",
        sandbox: .init(backend: .container, container: .init(image: "fixture:local"),
          admission: .init(directoryEnvironment: capacity == 1 ? "TEST_POOL" : "TEST_POOL_B", capacity: capacity))),
        promptText: "synthetic", sessionPolicy: policy, executionIdentity: stepIdentity), context: .init())
    }
    let calls = await runner.calls
    let reuse = try JSONDecoder().decode(SandboxNodeRequest.self, from: Data(try XCTUnwrap(calls.last?.1).utf8))
    XCTAssertEqual(reuse.previousVendorSessionId, "vendor-session")
  }

  // MARK: - jsonSchemaFrom + nativeStructuredOutput through the runner (review C unverified item)

  func testRunnerResolvedDynamicSchemaReachesNativeStructuredWorkerRequest() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("native-schema-from")
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = EphemeralFixtureRunner(workerRecords: [[Self.resultRecord(["status": .string("ok")])]])
    let result = try await runSandboxedWorkflow(adapter: dockerAdapter(runner, root: root),
      sandbox: .init(backend: .container, container: .init(image: "fixture:local"), ephemeralHome: true),
      output: .init(jsonSchemaFrom: "/dynamicSchema", nativeStructuredOutput: true),
      variables: ["dynamicSchema": .object(Self.statusSchema)])
    XCTAssertEqual(result.status, .completed)
    let calls = await runner.calls
    let worker = try XCTUnwrap(calls.first { $0.0.arguments.last == SandboxNodeWorker.command })
    let request = try JSONDecoder().decode(SandboxNodeRequest.self, from: Data(try XCTUnwrap(worker.1).utf8))
    XCTAssertEqual(request.input.node.output?.jsonSchema, Self.statusSchema)
    XCTAssertNil(request.input.node.output?.jsonSchemaFrom)
    XCTAssertEqual(request.capabilities, [.validationRejection, .ephemeralHome, .nativeStructuredOutput])
  }

  private static let statusSchema: JSONObject = ["type": .string("object"), "required": .array([.string("status")]),
    "properties": .object(["status": .object(["const": .string("ok")])])]

  fileprivate static func resultRecord(_ payload: JSONObject) -> SandboxNodeRecord {
    .init(kind: .result, output: .init(provider: "fixture", model: "fixture", promptText: "",
      completionPassed: true, payload: payload))
  }

  private func dockerAdapter(_ runner: EphemeralFixtureRunner, root: URL) -> SandboxingNodeAdapter {
    SandboxingNodeAdapter(primary: EphemeralForbiddenHost(), environment: [
      "RIELA_SANDBOX_WORKER_EXECUTABLE": workerPath, "RIELA_CONTAINER_RUNTIME": "docker"
    ], workingDirectory: root.path, runner: runner, directoryParent: root)
  }

  private func runSandboxedWorkflow(adapter: SandboxingNodeAdapter, sandbox: WorkflowExecutionSandbox,
                                    output: NodeOutputContract, variables: JSONObject = [:]) async throws -> WorkflowRunResult {
    let workflow = WorkflowDefinition(workflowId: "sandboxed",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3), entryStepId: "step",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json")],
      steps: [WorkflowStepRef(id: "step", nodeId: "node")], nodes: [WorkflowNodeRef(id: "step", nodeFile: "nodes/node.json")])
    let payload = AgentNodePayload(id: "node", executionBackend: .codexAgent, model: "fixture", sandbox: sandbox,
      agentSandbox: .readOnly, output: output)
    return try await DeterministicWorkflowRunner(store: InMemoryWorkflowRuntimeStore(), adapter: adapter)
      .run(.init(workflow: workflow, nodePayloads: ["node": payload], variables: variables))
  }

  private var workerPath: String {
    Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
      .appendingPathComponent("riela").resolvingSymlinksInPath().path
  }
}

private actor EphemeralFixtureRunner: LocalProcessRunning {
  var calls: [(LocalProcessConfiguration, String?)] = []
  var failExec: Bool
  var pool: URL?
  var heldObservations = 0
  /// Records per worker invocation; the last entry repeats.
  var workerRecords: [[SandboxNodeRecord]]
  var workerStatus: Int32
  var workerCalls = 0
  init(failExec: Bool = false, pool: URL? = nil, workerRecords: [[SandboxNodeRecord]] = [], workerStatus: Int32 = 0) {
    self.failExec = failExec; self.pool = pool; self.workerRecords = workerRecords; self.workerStatus = workerStatus
  }
  func run(configuration: LocalProcessConfiguration, stdin: String, deadline: Date?) async throws -> LocalProcessResult {
    calls.append((configuration, stdin))
    if let pool {
      do {
        _ = try await SandboxExecutionAdmission.acquire(.init(directoryEnvironment: "TEST_POOL", capacity: 1),
          environment: ["TEST_POOL": pool.path], deadline: Date().addingTimeInterval(0.04))
        XCTFail("container stage ran without holding admission")
      } catch let error as AdapterExecutionError {
        XCTAssertEqual(error.code, .timeout); heldObservations += 1
      }
    }
    if failExec, configuration.arguments.contains("exec") { throw CancellationError() }
    let isWorker = configuration.arguments.last == SandboxNodeWorker.command
    var records = [EphemeralSandboxTests.resultRecord(["status": .string("ok")])]
    if isWorker {
      workerCalls += 1
      if !workerRecords.isEmpty { records = workerRecords[min(workerCalls, workerRecords.count) - 1] }
    }
    let stdout = try records.map { (String(bytes: try JSONEncoder().encode($0), encoding: .utf8) ?? "") + "\n" }.joined()
    return .init(stdout: stdout, stderr: "", terminationStatus: isWorker ? workerStatus : 0)
  }
}

private struct EphemeralForbiddenHost: NodeAdapter {
  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    XCTFail("ephemeral sandbox must not fall back to host execution")
    throw AdapterExecutionError(.policyBlocked, "host fallback forbidden")
  }
}
