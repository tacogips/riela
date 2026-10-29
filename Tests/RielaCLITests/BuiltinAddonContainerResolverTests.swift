import Foundation
import RielaAdapters
import RielaCore
import RielaKaibaAddons
import RielaKaibaSupport
import XCTest
@testable import RielaCLI

final class BuiltinAddonContainerResolverTests: XCTestCase {
  func testMediaAddonsSelectVideoImageOnlyWhenImageIsOmitted() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("video-addon-image-selection")
    defer { try? FileManager.default.removeItem(at: root) }
    let addonNames = ["riela/media-download", "riela/audio-segments", "riela/video-frames", "riela/speech-to-text",
      "riela/video-transcribe"]

    for (index, name) in addonNames.enumerated() {
      let runner = BuiltinContainerRecordingRunner(output: testOutput())
      let resolver = BuiltinAddonContainerResolver(transportRootDirectory: builtinContainerTransportRoot(for: root, testCase: self),
        primary: ContainerTestNativeResolver(), environment: ["RIELA_CONTAINER_RUNTIME": "docker"],
        workingDirectory: root, runner: runner)
      _ = try await resolver.execute(.init(workflowId: "video", stepId: "step-\(index)", nodeId: "node-\(index)",
        addon: .init(name: name, version: "1", container: .init())), context: .init())
      let configurations = await runner.configurations
      let arguments = try XCTUnwrap(configurations.first?.arguments)
      XCTAssertTrue(arguments.contains("riela-video-addons:local"), "\(name) should select the video image")
    }

    let explicitImages = ["custom:media", WorkflowAddonContainerExecution.defaultImage]
    for (index, image) in explicitImages.enumerated() {
      let runner = BuiltinContainerRecordingRunner(output: testOutput())
      let resolver = BuiltinAddonContainerResolver(transportRootDirectory: builtinContainerTransportRoot(for: root, testCase: self),
        primary: ContainerTestNativeResolver(), environment: ["RIELA_CONTAINER_RUNTIME": "docker"],
        workingDirectory: root, runner: runner)
      _ = try await resolver.execute(.init(workflowId: "video", stepId: "explicit-\(index)", nodeId: "explicit-\(index)",
        addon: .init(name: "riela/video-frames", version: "1", container: .init(image: image))), context: .init())
      let configurations = await runner.configurations
      let arguments = try XCTUnwrap(configurations.first?.arguments)
      XCTAssertTrue(arguments.contains(image), "an explicit image must take precedence")
    }

    let omitted = try JSONDecoder().decode(WorkflowAddonContainerExecution.self, from: Data("{}".utf8))
    let explicitDefault = try JSONDecoder().decode(WorkflowAddonContainerExecution.self,
      from: Data(#"{"image":"riela-builtin-addons:local"}"#.utf8))
    XCTAssertFalse(omitted.imageWasSpecified)
    XCTAssertTrue(explicitDefault.imageWasSpecified)
    var changedAfterInitialization = WorkflowAddonContainerExecution()
    changedAfterInitialization.image = WorkflowAddonContainerExecution.defaultImage
    XCTAssertTrue(changedAfterInitialization.imageWasSpecified)
  }

  func testSandboxFinalizationRetainsAdmissionForExecuteAcknowledgeAndTerminal() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("addon-finalization-admission")
    defer { try? FileManager.default.removeItem(at: root) }
    let pool = root.appendingPathComponent("pool")
    let token = WorkflowAddonFinalizationToken(value: "synthetic-resource-token")
    let output = AdapterExecutionOutput(provider: "fixture", model: "fixture", promptText: "", completionPassed: true,
      payload: [:], runtimeFinalizationToken: token)
    let runner = BuiltinContainerRecordingRunner(output: output, pool: pool)
    let worker = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent(".build/debug/riela").resolvingSymlinksInPath().path
    let resolver = BuiltinAddonContainerResolver(transportRootDirectory: builtinContainerTransportRoot(for: root, testCase: self),
      primary: ContainerTestNativeResolver(), environment: ["RIELA_CONTAINER_RUNTIME": "docker", "TEST_POOL": pool.path,
        "RIELA_SANDBOX_WORKER_EXECUTABLE": worker], workingDirectory: root, runner: runner)
    let input = WorkflowAddonExecutionInput(workflowId: "fixture", stepId: "commit", nodeId: "commit",
      addon: .init(name: "riela/git-commit", version: "1", sandbox: .init(backend: .container,
        admission: .init(directoryEnvironment: "TEST_POOL", capacity: 1, minimumRemainingSeconds: 90))),
      executionIdentity: .init(workflowExecutionId: "admitted-session", stepExecutionId: "admitted-step",
        operationExecutionId: "admitted-step", attempt: 1))
    _ = try await resolver.execute(input, context: .init(deadline: Date().addingTimeInterval(120)))
    try await resolver.acknowledgeAcceptedFinalization(token)
    try await resolver.recordTerminalFinalization(workflowExecutionId: "admitted-session", stepExecutionIds: ["admitted-step"])
    let requests = await runner.requests
    XCTAssertEqual(requests.map(\.operation), [.execute, .acknowledge, .terminal])
    let observations = await runner.heldObservations
    XCTAssertEqual(observations, 3)
  }

  func testTerminalFinalizationContinuesPastAFailedInvocationAndKeepsRecords() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("addon-terminal-continues")
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = BuiltinContainerRecordingRunner(output: testOutput())
    let resolver = BuiltinAddonContainerResolver(transportRootDirectory: builtinContainerTransportRoot(for: root, testCase: self),
      primary: ContainerTestNativeResolver(), environment: ["RIELA_CONTAINER_RUNTIME": "docker"],
      workingDirectory: root, runner: runner)
    for image in ["first:image", "second:image"] {
      _ = try await resolver.execute(.init(workflowId: "w", stepId: "commit", nodeId: "commit",
        addon: .init(name: "riela/git-commit", version: "1", container: .init(image: image)),
        executionIdentity: .init(workflowExecutionId: "terminal-session", stepExecutionId: "step-\(image)",
          operationExecutionId: "step-\(image)", attempt: 1)), context: .init())
    }
    await runner.failTerminalCalls(1, status: 9)
    do {
      try await resolver.recordTerminalFinalization(workflowExecutionId: "terminal-session", stepExecutionIds: ["s"])
      XCTFail("a failed terminal invocation was swallowed")
    } catch let error as AdapterExecutionError {
      // Shared isolated-worker exit mapping (same contract as the node and private hosts).
      XCTAssertEqual(error.code, .providerError)
      XCTAssertEqual(error.message, "built-in add-on worker exited with status 9")
    }
    var terminals = await runner.requests.filter { $0.operation == .terminal }
    XCTAssertEqual(terminals.count, 2, "the second invocation must still receive its terminal record")
    // Records survive the failure, so a re-drive reaches both invocations again.
    try await resolver.recordTerminalFinalization(workflowExecutionId: "terminal-session", stepExecutionIds: ["s"])
    terminals = await runner.requests.filter { $0.operation == .terminal }
    XCTAssertEqual(terminals.count, 4)
    try await resolver.recordTerminalFinalization(workflowExecutionId: "terminal-session", stepExecutionIds: ["s"])
    terminals = await runner.requests.filter { $0.operation == .terminal }
    XCTAssertEqual(terminals.count, 4, "records are removed once every invocation succeeded")
  }

  func testTerminalFinalizationUnderSaturatedPoolTimesOutAndKeepsRecords() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("addon-terminal-saturated")
    defer { try? FileManager.default.removeItem(at: root) }
    let pool = root.appendingPathComponent("pool")
    let runner = BuiltinContainerRecordingRunner(output: testOutput())
    let worker = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent(".build/debug/riela").resolvingSymlinksInPath().path
    let resolver = BuiltinAddonContainerResolver(transportRootDirectory: builtinContainerTransportRoot(for: root, testCase: self),
      primary: ContainerTestNativeResolver(), environment: ["RIELA_CONTAINER_RUNTIME": "docker", "TEST_POOL": pool.path,
        "RIELA_SANDBOX_WORKER_EXECUTABLE": worker], workingDirectory: root, runner: runner)
    let admission = WorkflowExecutionAdmission(directoryEnvironment: "TEST_POOL", capacity: 1, waitTimeoutSeconds: 1)
    _ = try await resolver.execute(.init(workflowId: "w", stepId: "commit", nodeId: "commit",
      addon: .init(name: "riela/git-commit", version: "1", sandbox: .init(backend: .container, admission: admission)),
      executionIdentity: .init(workflowExecutionId: "busy-session", stepExecutionId: "busy-step",
        operationExecutionId: "busy-step", attempt: 1)), context: .init())
    var held = try await SandboxExecutionAdmission.acquire(admission, environment: ["TEST_POOL": pool.path], deadline: nil)
    do {
      try await resolver.recordTerminalFinalization(workflowExecutionId: "busy-session", stepExecutionIds: ["busy-step"])
      XCTFail("terminal worker ran outside a saturated pool")
    } catch let error as AdapterExecutionError { XCTAssertEqual(error.code, .timeout) }
    XCTAssertNotNil(held); held = nil
    try await resolver.recordTerminalFinalization(workflowExecutionId: "busy-session", stepExecutionIds: ["busy-step"])
    let operations = await runner.requests.map(\.operation)
    XCTAssertEqual(operations, [.execute, .terminal])
  }

  func testAdmissionWaitPolicyDoesNotRelocateSandboxWorkerState() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("addon-admission-state")
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = BuiltinContainerRecordingRunner(output: testOutput())
    let worker = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent(".build/debug/riela").resolvingSymlinksInPath().path
    let resolver = BuiltinAddonContainerResolver(transportRootDirectory: builtinContainerTransportRoot(for: root, testCase: self),
      primary: ContainerTestNativeResolver(), environment: ["RIELA_CONTAINER_RUNTIME": "docker", "TEST_POOL": root.appendingPathComponent("pool").path,
        "RIELA_SANDBOX_WORKER_EXECUTABLE": worker], workingDirectory: root, runner: runner)
    for seconds in [1, 2] {
      _ = try await resolver.execute(.init(workflowId: "fixture", stepId: "read", nodeId: "read",
        addon: .init(name: "riela/time-signal", version: "1", sandbox: .init(backend: .container,
          admission: .init(directoryEnvironment: "TEST_POOL", capacity: 1, waitTimeoutSeconds: seconds)))), context: .init())
    }
    let configurations = await runner.configurations
    let states = configurations.map { $0.arguments.filter { $0.hasPrefix("RIELA_ADDON_STATE_DIR=") } }
    XCTAssertEqual(states.count, 2); XCTAssertFalse(states[0].isEmpty); XCTAssertEqual(states[0], states[1])
  }

  func testHostControlDirectoryCannotBeExposedByWorkspaceOrExplicitMount() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("container-control-isolation")
    defer { try? FileManager.default.removeItem(at: root) }
    let control = builtinContainerTransportRoot(for: root, testCase: self)
    let recorder = BuiltinContainerRecordingRunner(output: testOutput())
    let resolver = BuiltinAddonContainerResolver(transportRootDirectory: control,
      primary: ContainerTestNativeResolver(), environment: [:], workingDirectory: root, runner: recorder)
    for source in [control, control.deletingLastPathComponent(), BuiltinAddonContainerTransportStore.workerStateRoot(for: control).deletingLastPathComponent()] {
      do {
        _ = try await resolver.execute(.init(workflowId: "w", stepId: "s", nodeId: "n",
          addon: .init(name: "riela/time-signal", container: .init(mounts: [.init(source: source.path, target: "/control")]))), context: .init())
        XCTFail("host authority must never enter the guest filesystem")
      } catch let error as AdapterExecutionError { XCTAssertEqual(error.code, .policyBlocked) }
    }
    let broad = BuiltinAddonContainerResolver(transportRootDirectory: control, primary: ContainerTestNativeResolver(),
      environment: [:], workingDirectory: root.deletingLastPathComponent(), runner: recorder)
    do {
      _ = try await broad.execute(.init(workflowId: "w", stepId: "s", nodeId: "n",
        addon: .init(name: "riela/time-signal", container: .init())), context: .init())
      XCTFail("a broad workspace must not expose host authority")
    } catch let error as AdapterExecutionError { XCTAssertEqual(error.code, .policyBlocked) }
    let requests = await recorder.requests
    XCTAssertTrue(requests.isEmpty)
  }

  func testLoopbackKaibaCredentialStaysOnHost() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("kaiba-loopback-credential")
    defer { try? FileManager.default.removeItem(at: root) }
    let instance = KaibaInstance(name: "Local", endpoint: "http://127.0.0.1:8787/graphql",
      authentication: .bearer(environmentVariable: "KAIBA_TOKEN"), isDefault: true)
    let environment = ["KAIBA_TOKEN": "host-only-secret", "RIELA_CONTAINER_RUNTIME": "docker"]
    let snapshot = try KaibaExecutionSnapshot(bindingIDs: [nil], catalog: .init(instances: [instance]), environment: environment)
    let recorder = BuiltinContainerRecordingRunner(output: testOutput())
    let resolver = BuiltinAddonContainerResolver(transportRootDirectory: builtinContainerTransportRoot(for: root, testCase: self), primary: ContainerTestNativeResolver(), environment: environment,
      workingDirectory: root, runner: recorder)
    _ = try await KaibaAddonExecutionContext.withSnapshot(snapshot, allowsMockExecution: false) {
      try await resolver.execute(.init(workflowId: "fixture", stepId: "note", nodeId: "note",
        addon: .init(name: "kaiba/note-get", container: .init(networkPolicy: .denied))), context: .init())
    }
    let requests = await recorder.requests
    let request = try XCTUnwrap(requests.first)
    XCTAssertNotNil(request.nativeKaibaBridgeDirectory)
    XCTAssertEqual(request.kaibaInstance?.credentialEnvironmentVariable, "KAIBA_TOKEN")
    let wire = try XCTUnwrap(String(data: JSONEncoder().encode(request), encoding: .utf8))
    XCTAssertFalse(wire.contains("host-only-secret"))
    let configurations = await recorder.configurations
    let arguments = try XCTUnwrap(configurations.first).arguments
    XCTAssertFalse(arguments.contains("KAIBA_TOKEN=host-only-secret"))
  }

  func testKaibaContainerCapturesOnlySelectedInstanceAndItsCredential() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("kaiba-container-capture")
    defer { try? FileManager.default.removeItem(at: root) }
    let selected = KaibaInstance(id: UUID().uuidString.lowercased(), name: "Selected",
      endpoint: "https://selected.example/graphql", authentication: .bearer(environmentVariable: "SELECTED_TOKEN"))
    let other = KaibaInstance(id: UUID().uuidString.lowercased(), name: "Default",
      endpoint: "https://other.example/graphql", authentication: .bearer(environmentVariable: "OTHER_TOKEN"), isDefault: true)
    let environment = ["SELECTED_TOKEN": "selected-secret", "OTHER_TOKEN": "other-secret", "RIELA_CONTAINER_RUNTIME": "docker"]
    let snapshot = try KaibaExecutionSnapshot(bindingIDs: [selected.id],
      catalog: .init(instances: [other, selected]), environment: environment)
    let recorder = BuiltinContainerRecordingRunner(output: testOutput())
    let resolver = BuiltinAddonContainerResolver(transportRootDirectory: builtinContainerTransportRoot(for: root, testCase: self), primary: ContainerTestNativeResolver(), environment: environment,
      workingDirectory: root, runner: recorder)
    _ = try await KaibaAddonExecutionContext.withSnapshot(snapshot, allowsMockExecution: false) {
      try await resolver.execute(.init(workflowId: "fixture", stepId: "note", nodeId: "note",
        addon: .init(name: "kaiba/note-get", version: "1", config: ["kaibaInstanceId": .string(selected.id)],
          container: .init())), context: .init())
    }
    let requests = await recorder.requests
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.kaibaInstance?.id, selected.id)
    XCTAssertEqual(request.kaibaInstance?.endpoint, selected.endpoint)
    let wire = try XCTUnwrap(String(data: JSONEncoder().encode(request), encoding: .utf8))
    XCTAssertFalse(wire.contains("selected-secret"))
    XCTAssertFalse(wire.contains(other.endpoint))
    let configurations = await recorder.configurations
    let arguments = try XCTUnwrap(configurations.first).arguments
    XCTAssertTrue(arguments.contains("SELECTED_TOKEN=selected-secret"))
    XCTAssertFalse(arguments.contains("OTHER_TOKEN=other-secret"))
  }

  func testKaibaContainerCannotSelectDefaultWithoutPreflightSnapshot() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("kaiba-container-no-snapshot")
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = BuiltinContainerRecordingRunner(output: testOutput())
    let resolver = BuiltinAddonContainerResolver(transportRootDirectory: builtinContainerTransportRoot(for: root, testCase: self), primary: ContainerTestNativeResolver(), environment: [:],
      workingDirectory: root, runner: recorder)
    do {
      _ = try await resolver.execute(.init(workflowId: "fixture", stepId: "note", nodeId: "note",
        addon: .init(name: "kaiba/note-get", container: .init())), context: .init())
      XCTFail("a missing captured selection must fail before launching the guest")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
    }
    let requests = await recorder.requests
    XCTAssertTrue(requests.isEmpty)
  }

  func testContainerExecutionPreservesIdentityAndRoutesFinalizationBackToWorker() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("builtin-container-resolver")
    defer { try? FileManager.default.removeItem(at: root) }
    let token = WorkflowAddonFinalizationToken(value: "runtime-token")
    let output = AdapterExecutionOutput(provider: "guest", model: "test", promptText: "", completionPassed: true,
      when: ["always": true, "selected": true], payload: ["value": .integer(3)], usage: .init(totalTokens: 8), runtimeFinalizationToken: token)
    let runner = BuiltinContainerRecordingRunner(output: output)
    let native = ContainerTestNativeResolver()
    let resolver = BuiltinAddonContainerResolver(transportRootDirectory: builtinContainerTransportRoot(for: root, testCase: self), primary: native,
      environment: ["RIELA_CONTAINER_RUNTIME": "docker", "HOST_TOKEN": "bound-secret", "UNRELATED": "private"],
      workingDirectory: root, runner: runner)
    let input = WorkflowAddonExecutionInput(workflowId: "w", stepId: "s", nodeId: "n",
      addon: .init(name: "riela/git-commit", version: "1", env: ["TOKEN": .object(["fromEnv": .string("HOST_TOKEN")])], container: .init()),
      executionIdentity: .init(workflowExecutionId: "runtime-session", stepExecutionId: "runtime-step", operationExecutionId: "runtime-step", attempt: 1))
    let actualOutput = try await resolver.execute(input, context: .init())
    XCTAssertEqual(actualOutput, output)
    try await resolver.acknowledgeAcceptedFinalization(token)
    try await resolver.recordTerminalFinalization(workflowExecutionId: "runtime-session", stepExecutionIds: ["runtime-step"])
    let requests = await runner.requests
    let configurations = await runner.configurations
    XCTAssertEqual(requests.map(\.operation), [.execute, .acknowledge, .terminal])
    XCTAssertEqual(requests.first?.input?.executionIdentity, input.executionIdentity)
    XCTAssertNil(requests.first?.input?.addon.container)
    XCTAssertEqual(requests.first?.input?.addon.env?["TOKEN"], .object(["fromEnv": .string("TOKEN")]))
    XCTAssertEqual(requests[1].finalizationToken, token)
    for configuration in configurations {
      XCTAssertTrue(configuration.arguments.contains("TOKEN=bound-secret"))
      XCTAssertFalse(configuration.arguments.contains("UNRELATED=private"))
      XCTAssertTrue(configuration.arguments.contains(WorkflowAddonContainerExecution.workerEntrypoint))
      XCTAssertTrue(configuration.arguments.contains("--read-only"))
    }
    let nativeExecutions = await native.executions
    let nativeAcknowledgments = await native.acknowledgments
    XCTAssertEqual(nativeExecutions, 0)
    XCTAssertEqual(nativeAcknowledgments, 0)
  }

  func testFreshResolverRestoresTransportWithoutPersistingCredentialValues() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("resumed-container-finalization")
    defer { try? FileManager.default.removeItem(at: root) }
    let token = WorkflowAddonFinalizationToken(value: "runtime-token")
    var output = testOutput()
    output.runtimeFinalizationToken = token
    let runner = BuiltinContainerRecordingRunner(output: output)
    let addon = WorkflowNodeAddonRef(name: "riela/git-commit", version: "1",
      env: ["TOKEN": .object(["fromEnv": .string("HOST_TOKEN")])], container: .init(image: "pinned:worker", runtime: .docker))
    let input = WorkflowAddonExecutionInput(workflowId: "w", stepId: "s", nodeId: "n", addon: addon,
      executionIdentity: .init(workflowExecutionId: "runtime-session", stepExecutionId: "runtime-step", attempt: 1))
    let first = BuiltinAddonContainerResolver(transportRootDirectory: builtinContainerTransportRoot(for: root, testCase: self), primary: ContainerTestNativeResolver(), environment: ["HOST_TOKEN": "first-secret"],
      workingDirectory: root, runner: runner)
    _ = try await first.execute(input, context: .init())
    let transportRoot = builtinContainerTransportRoot(for: root, testCase: self)
    let files: [URL] = try {
      let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: transportRoot, includingPropertiesForKeys: nil))
      return enumerator.allObjects.compactMap { $0 as? URL }
    }()
    for url in files where url.pathExtension == "json" {
      let contents = try String(contentsOf: url, encoding: .utf8)
      XCTAssertFalse(contents.contains("first-secret"))
      XCTAssertTrue(contents.contains("HOST_TOKEN"))
    }
    let native = ContainerTestNativeResolver()
    let resumed = BuiltinAddonContainerResolver(transportRootDirectory: builtinContainerTransportRoot(for: root, testCase: self), primary: native, environment: ["HOST_TOKEN": "rotated-secret"],
      workingDirectory: root, runner: runner)
    try await resumed.acknowledgeAcceptedFinalization(token)
    let terminal = BuiltinAddonContainerResolver(transportRootDirectory: builtinContainerTransportRoot(for: root, testCase: self), primary: native, environment: ["HOST_TOKEN": "rotated-secret"],
      workingDirectory: root, runner: runner)
    try await terminal.recordTerminalFinalization(workflowExecutionId: "runtime-session", stepExecutionIds: ["runtime-step"])
    let repeated = BuiltinAddonContainerResolver(transportRootDirectory: transportRoot, primary: native,
      environment: [:], workingDirectory: root, runner: runner)
    try await repeated.acknowledgeAcceptedFinalization(token)
    let requests = await runner.requests
    let configurations = await runner.configurations
    XCTAssertEqual(requests.map(\.operation), [.execute, .acknowledge, .terminal])
    XCTAssertEqual(requests[2].workflowExecutionId, "runtime-session")
    XCTAssertEqual(requests[2].stepExecutionIds, ["runtime-step"])
    XCTAssertTrue(configurations[1].arguments.contains("TOKEN=rotated-secret"))
    XCTAssertTrue(configurations[2].arguments.contains("pinned:worker"))
    let nativeAcknowledgments = await native.acknowledgments
    XCTAssertEqual(nativeAcknowledgments, 0)
    let store = BuiltinAddonContainerTransportStore(workingDirectory: root, rootDirectory: builtinContainerTransportRoot(for: root, testCase: self))
    XCTAssertTrue(try store.isAcknowledged(token))
    XCTAssertTrue(try store.invocations(workflowExecutionId: "runtime-session").isEmpty)
  }

  func testUnavailableResumedCredentialFailsWithoutNativeFallbackAndKeepsTransport() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("missing-resumed-container-credential")
    defer { try? FileManager.default.removeItem(at: root) }
    let token = WorkflowAddonFinalizationToken(value: "pending-token")
    let store = BuiltinAddonContainerTransportStore(workingDirectory: root, rootDirectory: builtinContainerTransportRoot(for: root, testCase: self))
    try store.record(.init(settings: .init(runtime: .docker),
      environmentBindings: ["TOKEN": .object(["fromEnv": .string("MISSING")])]), token: token)
    let native = ContainerTestNativeResolver()
    let runner = BuiltinContainerRecordingRunner(output: testOutput())
    let resolver = BuiltinAddonContainerResolver(transportRootDirectory: builtinContainerTransportRoot(for: root, testCase: self), primary: native, environment: [:], workingDirectory: root, runner: runner)
    do {
      try await resolver.acknowledgeAcceptedFinalization(token)
      XCTFail("missing credential must fail closed")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
    }
    XCTAssertNotNil(try store.invocation(for: token))
    let acknowledgments = await native.acknowledgments
    let requests = await runner.requests
    XCTAssertEqual(acknowledgments, 0)
    XCTAssertTrue(requests.isEmpty)
  }

  func testNativeExecutionDoesNotLaunchContainer() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("builtin-native-resolver")
    defer { try? FileManager.default.removeItem(at: root) }
    let native = ContainerTestNativeResolver()
    let runner = BuiltinContainerRecordingRunner(output: testOutput())
    let resolver = BuiltinAddonContainerResolver(transportRootDirectory: builtinContainerTransportRoot(for: root, testCase: self), primary: native, environment: [:], workingDirectory: root, runner: runner)
    _ = try await resolver.execute(.init(workflowId: "w", stepId: "s", nodeId: "n", addon: .init(name: "riela/time-signal")), context: .init())
    let executions = await native.executions
    let requests = await runner.requests
    XCTAssertEqual(executions, 1)
    XCTAssertTrue(requests.isEmpty)
  }

  func testNonFinalizingContainerAddonDoesNotReceiveGitTerminalControl() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("nonfinalizing-container-addon")
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = BuiltinContainerRecordingRunner(output: testOutput())
    let resolver = BuiltinAddonContainerResolver(transportRootDirectory: builtinContainerTransportRoot(for: root, testCase: self),
      primary: ContainerTestNativeResolver(), environment: ["RIELA_CONTAINER_RUNTIME": "docker"],
      workingDirectory: root, runner: runner)
    _ = try await resolver.execute(.init(workflowId: "w", stepId: "s", nodeId: "n", addon: .init(name: "riela/time-signal", container: .init()),
      executionIdentity: .init(workflowExecutionId: "runtime-session", stepExecutionId: "runtime-step", attempt: 1)), context: .init())
    try await resolver.recordTerminalFinalization(workflowExecutionId: "runtime-session", stepExecutionIds: ["runtime-step"])
    let requests = await runner.requests
    XCTAssertEqual(requests.map(\.operation), [.execute])
  }

  func testEmptyContainerSelectionKeepsLegacyGatewayMountsAndNetworkDenial() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("legacy-gateway-container-selection")
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = LegacyGatewayContainerRunner()
    let resolver = BuiltinAddonContainerResolver(transportRootDirectory: builtinContainerTransportRoot(for: root, testCase: self),
      primary: ContainerTestNativeResolver(), environment: ["RIELA_CONTAINER_RUNTIME": "docker"],
      workingDirectory: root, runner: runner)
    _ = try await resolver.execute(.init(workflowId: "w", stepId: "s", nodeId: "n", addon: .init(name: "riela/gmail-gateway-read", config: [
      "queryTemplate": .string("query { accounts { id } }"), "image": .string("custom:gmail"), "networkPolicy": .string("denied"),
      "mounts": .array([.object(["source": .string(root.path), "target": .string("/credentials")])])
    ], container: .init())), context: .init())
    let recordedConfiguration = await runner.configuration
    let configuration = try XCTUnwrap(recordedConfiguration)
    XCTAssertTrue(configuration.arguments.contains(root.path + ":/credentials:ro"))
    XCTAssertTrue(configuration.arguments.contains("none"))
    XCTAssertTrue(configuration.arguments.contains("custom:gmail"))
  }

  func testWorkerExecutesRealTimeSignalAndPreservesConditions() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("builtin-time-worker")
    defer { try? FileManager.default.removeItem(at: root) }
    let input = WorkflowAddonExecutionInput(workflowId: "w", stepId: "s", nodeId: "n", addon: .init(name: "riela/time-signal", version: "1"),
      variables: ["scheduledAt": .string("2026-10-15T00:00:00Z"), "timezone": .string("UTC")])
    let reply = await BuiltinAddonWorker.execute(.init(operation: .execute, input: input), environment: [:], workingDirectory: root)
    let output = try XCTUnwrap(try reply.validatedOutput(for: .execute))
    XCTAssertEqual(output.when["should_announce"], true)
    XCTAssertEqual(output.payload["timezone"], .string("UTC"))
    let expired = await BuiltinAddonWorker.execute(.init(operation: .execute, input: input, deadline: Date(timeIntervalSince1970: 0)), environment: [:], workingDirectory: root)
    XCTAssertEqual(expired.failure?.code, .timeout)
  }

  func testStandaloneWorkerReadsAndWritesJSONL() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("builtin-stdio-worker")
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent(".build/debug/riela-addon-worker")
    let input = WorkflowAddonExecutionInput(workflowId: "w", stepId: "s", nodeId: "n", addon: .init(name: "riela/time-signal", version: "1"),
      variables: ["scheduledAt": .string("2026-10-15T00:00:00Z"), "timezone": .string("UTC")])
    let request = BuiltinAddonContainerRequest(operation: .execute, input: input)
    let stdin = try XCTUnwrap(String(data: JSONEncoder().encode(request), encoding: .utf8))
    let result = try await FoundationLocalProcessRunner().run(configuration: .init(executableURL: executable,
      arguments: [], environment: ["HOME": root.path], workingDirectoryURL: root), stdin: stdin + "\n", deadline: Date().addingTimeInterval(30))
    XCTAssertEqual(result.terminationStatus, 0)
    XCTAssertEqual(result.stdout.split(whereSeparator: \.isNewline).count, 1)
    let reply = try JSONDecoder().decode(BuiltinAddonContainerReply.self, from: Data(result.stdout.utf8))
    XCTAssertEqual(try reply.validatedOutput(for: .execute)?.when["should_announce"], true)
  }

  func testWorkerWrikeReaderAndWriterEnforceCapabilityTiersWithoutCredentials() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("wrike-worker-capabilities")
    defer { try? FileManager.default.removeItem(at: root) }
    let cases = [
      ("riela/wrike-gateway-read", "mutation { createTask(folderId: \"unused\", title: \"must not create\") { id } }", "writer"),
      ("riela/wrike-gateway-write", "mutation { deleteTask(taskId: \"must not delete\") { id } }", "admin")
    ]
    for (name, document, requiredTier) in cases {
      let input = WorkflowAddonExecutionInput(workflowId: "probe", stepId: "tier", nodeId: "tier",
        addon: .init(name: name, version: "1", config: ["queryTemplate": .string(document)]))
      let reply = await BuiltinAddonWorker.execute(.init(operation: .execute, input: input), environment: [:], workingDirectory: root)
      let failure = try XCTUnwrap(reply.failure)
      XCTAssertEqual(failure.code, .providerError)
      XCTAssertTrue(failure.message.contains("requires the " + requiredTier + " capability tier"), failure.message)
    }
  }

  func testNodeCLIParsesContainerSelectionAndAppliesAddonConfig() async throws {
    let parsed = try ParsedParityOptions(["--container", "--container-image", "custom:worker", "--container-options", #"{"runtime":"docker"}"#])
    XCTAssertTrue(parsed.container)
    XCTAssertEqual(parsed.containerImage, "custom:worker")
    XCTAssertEqual(parsed.containerOptions, #"{"runtime":"docker"}"#)
    let root = try makeRielaCLITestTemporaryDirectory("node-config-options")
    defer { try? FileManager.default.removeItem(at: root) }
    let result = await NodeCommandRunner().run(.init(kind: .run, options: .init(scope: "node", command: "run", target: "riela/time-signal",
      arguments: ["--working-dir", root.path, "--config", #"{"intervalMinutes":60}"#,
        "--variables", #"{"scheduledAt":"2026-10-15T00:30:00Z","timezone":"UTC"}"#], output: .json)))
    XCTAssertEqual(result.exitCode, .success)
    let output = try JSONDecoder().decode(NodeRunCommandResult.self, from: Data(result.stdout.utf8))
    XCTAssertEqual(output.payload["intervalMinutes"], .number(60))
    XCTAssertEqual(output.payload["shouldAnnounce"], .bool(false))
  }

  private func testOutput() -> AdapterExecutionOutput {
    .init(provider: "test", model: "test", promptText: "", completionPassed: true, payload: [:])
  }
}

private actor BuiltinContainerRecordingRunner: LocalProcessRunning {
  var requests: [BuiltinAddonContainerRequest] = []
  var configurations: [LocalProcessConfiguration] = []
  let output: AdapterExecutionOutput
  let pool: URL?
  var heldObservations = 0
  var failingTerminalCalls = 0
  var failingStatus: Int32 = 1

  init(output: AdapterExecutionOutput, pool: URL? = nil) { self.output = output; self.pool = pool }

  func failTerminalCalls(_ count: Int, status: Int32) { failingTerminalCalls = count; failingStatus = status }

  func run(configuration: LocalProcessConfiguration, stdin: String, deadline: Date?) async throws -> LocalProcessResult {
    let request = try JSONDecoder().decode(BuiltinAddonContainerRequest.self, from: Data(stdin.utf8))
    try request.validate()
    if let pool {
      do {
        _ = try await SandboxExecutionAdmission.acquire(.init(directoryEnvironment: "TEST_POOL", capacity: 1),
          environment: ["TEST_POOL": pool.path], deadline: Date().addingTimeInterval(0.04))
        XCTFail("addon worker ran outside declared admission")
      } catch let error as AdapterExecutionError { XCTAssertEqual(error.code, .timeout); heldObservations += 1 }
    }
    requests.append(request)
    configurations.append(configuration)
    if request.operation == .terminal, failingTerminalCalls > 0 {
      failingTerminalCalls -= 1
      return .init(stdout: "", stderr: "", terminationStatus: failingStatus)
    }
    let reply = BuiltinAddonContainerReply(output: request.operation == .execute ? output : nil)
    let stdout = try XCTUnwrap(String(data: JSONEncoder().encode(reply), encoding: .utf8))
    return .init(stdout: stdout + "\n", stderr: "", terminationStatus: 0)
  }
}

private actor ContainerTestNativeResolver: WorkflowAddonResolving, WorkflowAddonFinalizationAcknowledging, WorkflowAddonTerminalRecording {
  var executions = 0
  var acknowledgments = 0

  func execute(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    executions += 1
    return .init(provider: "native", model: "test", promptText: "", completionPassed: true, payload: [:])
  }

  func acknowledgeAcceptedFinalization(_ token: WorkflowAddonFinalizationToken) async throws { acknowledgments += 1 }
  func recordTerminalFinalization(workflowExecutionId: String, stepExecutionIds: [String]) async throws {}
}

private actor LegacyGatewayContainerRunner: LocalProcessRunning {
  var configuration: LocalProcessConfiguration?
  func run(configuration: LocalProcessConfiguration, stdin: String, deadline: Date?) async throws -> LocalProcessResult {
    self.configuration = configuration
    return .init(stdout: #"{"data":{}}"#, stderr: "", terminationStatus: 0)
  }
}
