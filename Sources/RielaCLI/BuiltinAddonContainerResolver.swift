import Foundation
import RielaAdapters
import RielaCore
import RielaKaibaAddons
import RielaKaibaSupport

/// Worker control messages retain the selected container/native transport.
/// Tokens stay internal to the runtime boundary, including after resolver reopen.
actor BuiltinAddonContainerResolver: WorkflowAddonResolving, WorkflowAddonFinalizationAcknowledging,
  WorkflowAddonTerminalRecording {
  static let guestStateDirectory = "/var/lib/riela/state"
  private static let addonDefaultImages = [
    "riela/media-download": "riela-video-addons:local",
    "riela/audio-segments": "riela-video-addons:local",
    "riela/video-frames": "riela-video-addons:local",
    "riela/speech-to-text": "riela-video-addons:local",
    "riela/video-transcribe": "riela-video-addons:local"
  ]
  private typealias Invocation = BuiltinAddonContainerInvocation

  private let primary: any WorkflowAddonResolving
  private let environment: [String: String]
  private let workingDirectory: URL
  private let runner: any LocalProcessRunning
  private let hostPlatform: RielaHostPlatform
  private let nativeAppleGatewayRunner: AppleGatewayRunner?
  private let transportRootDirectory: URL
  private var transportStore: BuiltinAddonContainerTransportStore {
    .init(workingDirectory: workingDirectory, rootDirectory: transportRootDirectory)
  }

  init(
    transportRootDirectory: URL? = nil,
    primary: any WorkflowAddonResolving,
    environment: [String: String],
    workingDirectory: URL,
    runner: any LocalProcessRunning = FoundationLocalProcessRunner(),
    hostPlatform: RielaHostPlatform = .current,
    nativeAppleGatewayRunner: AppleGatewayRunner? = nil
  ) {
    self.primary = primary
    self.environment = environment
    self.workingDirectory = workingDirectory.standardizedFileURL
    self.runner = runner
    self.hostPlatform = hostPlatform
    self.nativeAppleGatewayRunner = nativeAppleGatewayRunner
    self.transportRootDirectory = transportRootDirectory ?? BuiltinAddonContainerTransportStore.defaultRoot(for: workingDirectory,
      home: URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory(environment: environment), isDirectory: true))
  }

  func execute(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    let plan = try BuiltinPostprocessPlan(input)
    let output = try await executeUnprocessed(plan.input, context: context)
    return plan.apply(to: output)
  }

  private func executeUnprocessed(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    let sandbox = input.addon.sandbox
    guard sandbox == nil || input.addon.container == nil else {
      throw AdapterExecutionError(.policyBlocked, "addon.sandbox and addon.container cannot be combined")
    }
    guard sandbox != nil || input.addon.container != nil else { return try await primary.execute(input, context: context) }
    let input = try prepareAppleGatewayContainerOperation(input, workingDirectory: workingDirectory)
    if input.addon.name == "riela/private-workflow" {
      return try await PrivateWorkflowHost(environment: environment, workingDirectory: workingDirectory, runner: runner)
        .execute(input, context: context)
    }
    try sandbox?.validate()
    guard sandbox?.ephemeralHome != true, sandbox?.credentialEnvironment.isEmpty != false else {
      throw AdapterExecutionError(.policyBlocked, "ephemeral HOME and credential files currently require a sandboxed agent node")
    }
    var settings = try sandbox.map(builtinSandboxContainerSettings) ?? input.addon.container ?? .init()
    if let defaultImage = Self.addonDefaultImages[input.addon.name], input.addon.container != nil,
       input.addon.container?.imageWasSpecified != true {
      settings.image = defaultImage
    }
    try settings.validate()
    guard input.addon.name.hasPrefix("riela/") || input.addon.name.hasPrefix("kaiba/") else {
      throw AdapterExecutionError(.policyBlocked, "addon.container currently requires a built-in add-on")
    }
    if let gateway = ContainerGatewayAddon(rawValue: input.addon.name) {
      // Static refusals come before admission so they never wait for a slot.
      if let sandbox {
        guard sandbox.backend == .container, sandbox.credentials.isEmpty else {
          throw AdapterExecutionError(.policyBlocked, "legacy gateway reader images require container isolation; use the SDK add-on or sandbox run with a host reader for native isolation")
        }
      }
      var gatewayInput = input
      gatewayInput.addon.container = nil
      gatewayInput.addon.sandbox = nil
      var config = input.addon.config ?? [:]
      if settings.image != WorkflowAddonContainerExecution.defaultImage { config["image"] = .string(settings.image) }
      if settings.runtime != .auto || config["runnerKind"] == nil { config["runnerKind"] = .string(settings.runtime.rawValue) }
      if settings.networkPolicy == .denied || config["networkPolicy"] == nil { config["networkPolicy"] = .string(settings.networkPolicy.rawValue) }
      if !settings.mounts.isEmpty || config["mounts"] == nil {
        config["mounts"] = .array(settings.mounts.map {
          .object(["source": .string($0.source), "target": .string($0.target), "readOnly": .bool($0.readOnly)])
        })
      }
      gatewayInput.addon.config = config
      let executor = ContainerGatewayAddonExecutor(environment: environment, workingDirectory: workingDirectory,
        runner: runner, hostPlatform: hostPlatform)
      return try await SandboxExecutionAdmission.withLease(sandbox?.admission, environment: environment,
        deadline: context.deadline) {
        try await executor.execute(gatewayInput, gateway: gateway, context: context)
      }
    }
    try validateControlIsolation(settings: settings)
    if let sandbox { try validateSandboxControlIsolation(sandbox) }
    var bindings = input.addon.env ?? [:]
    let kaibaInstance: BuiltinAddonKaibaInstance?
    if input.addon.name.hasPrefix("kaiba/") {
      guard KaibaAddonExecutionContext.snapshot != nil,
            let selected = try KaibaAddonExecutionContext.resolvedClient(for: input) else {
        throw AdapterExecutionError(.policyBlocked, "container Kaiba execution requires the preflight instance snapshot")
      }
      kaibaInstance = .init(instance: selected.instance)
      if let credential = kaibaInstance?.credentialEnvironmentVariable {
        let explicit = try resolveAddonEnvironment(input.addon.env, runtimeEnvironment: environment)[credential]
        guard explicit == nil || explicit == environment[credential] else {
          throw AdapterExecutionError(.policyBlocked, "container Kaiba credential binding must match the selected instance")
        }
        if !selected.client.endpoint.isLoopback {
          bindings[credential] = .object(["fromEnv": .string(credential)])
        }
      }
    } else { kaibaInstance = nil }
    let childEnvironment = try resolveAddonEnvironment(bindings, runtimeEnvironment: environment)
    guard childEnvironment["HOME"] == nil, childEnvironment["RIELA_ADDON_STATE_DIR"] == nil else {
      throw AdapterExecutionError(.policyBlocked, "container HOME and RIELA_ADDON_STATE_DIR are runtime-owned")
    }
    var workerInput = input
    workerInput.addon.container = nil
    workerInput.addon.sandbox = nil
    if BuiltinAppleGatewayAdminAddon(rawValue: input.addon.name) == .fileDownload,
       try AppleGatewayAdminContext(input: input, currentDirectory: workingDirectory).downloadOutputDirectory == nil {
      var inputs = workerInput.addon.inputs ?? [:]
      inputs["outputDir"] = .string(workingDirectory.appendingPathComponent("tmp/apple-gateway/downloads").path)
      workerInput.addon.inputs = inputs
    }
    // Bindings have already been resolved on the host. Guest-side add-on
    // validation still sees the same target names without host source names.
    if input.addon.env != nil || !bindings.isEmpty {
      workerInput.addon.env = Dictionary(uniqueKeysWithValues: childEnvironment.keys.map { key in
        (key, .object(["fromEnv": .string(key)]))
      })
    }
    let transportBindings = bindings.mapValues { value -> JSONValue in
      guard case let .object(binding) = value else { return value }
      return .object(binding.filter { $0.key == "fromEnv" || $0.key == "required" })
    }
    let executable: String
    if let sandbox {
      if sandbox.backend != .container { _ = try NativeProcessSandbox().selectedBackend(sandbox) }
      executable = try ExecutionSandboxLauncher(environment: environment).workerExecutable().path
    } else { executable = try runtimeDriver(settings: settings).executable }
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let stateComponent = try sandbox.map { selection in
      var stateSelection = selection
      stateSelection.admission = nil // Scheduling must not relocate persistent worker state.
      var scope = try encoder.encode(stateSelection)
      scope.append(try encoder.encode(transportBindings))
      scope.append(Data((input.addon.name + "/" + (input.executionIdentity?.workflowExecutionId ?? input.workflowId)).utf8))
      return sha256(scope)
    }
    let invocation = Invocation(settings: settings, environmentBindings: transportBindings, runtimeExecutable: executable,
      sandbox: sandbox, workerStateComponent: stateComponent)
    if BuiltinGitAddon(rawValue: input.addon.name) != nil, let workflowId = input.executionIdentity?.workflowExecutionId {
      // Persist before launching a side effect, including failed executions.
      try transportStore.record(invocation, workflowExecutionId: workflowId)
    }
    let reply = try await run(.init(operation: .execute, input: workerInput, deadline: context.deadline,
      kaibaInstance: kaibaInstance), invocation: invocation)
    guard let output = try reply.validatedOutput(for: .execute) else {
      throw AdapterExecutionError(.invalidOutput, "container worker returned no execution output")
    }
    if let token = output.runtimeFinalizationToken {
      try transportStore.record(invocation, token: token)
      if let workflowId = input.executionIdentity?.workflowExecutionId {
        try transportStore.record(invocation, workflowExecutionId: workflowId)
      }
    }
    return output
  }

  func acknowledgeAcceptedFinalization(_ token: WorkflowAddonFinalizationToken) async throws {
    if try transportStore.isAcknowledged(token) { return }
    guard let invocation = try transportStore.invocation(for: token) else {
      try await (primary as? any WorkflowAddonFinalizationAcknowledging)?.acknowledgeAcceptedFinalization(token)
      return
    }
    let reply = try await run(.init(operation: .acknowledge, finalizationToken: token,
      deadline: Date().addingTimeInterval(60)), invocation: invocation)
    _ = try reply.validatedOutput(for: .acknowledge)
    try transportStore.markAcknowledged(token)
  }

  /// One busy or failing invocation must not skip the others. Records are
  /// removed only after every invocation succeeded, so a later re-drive still
  /// finds the ones that failed; the first failure is rethrown.
  func recordTerminalFinalization(workflowExecutionId: String, stepExecutionIds: [String]) async throws {
    var firstFailure: (any Error)?
    for invocation in try transportStore.invocations(workflowExecutionId: workflowExecutionId) {
      do {
        let reply = try await run(.init(operation: .terminal, workflowExecutionId: workflowExecutionId,
          stepExecutionIds: stepExecutionIds, deadline: Date().addingTimeInterval(60)), invocation: invocation)
        _ = try reply.validatedOutput(for: .terminal)
      } catch {
        if error is CancellationError { throw error }
        firstFailure = firstFailure ?? error
      }
    }
    try await (primary as? any WorkflowAddonTerminalRecording)?.recordTerminalFinalization(
      workflowExecutionId: workflowExecutionId, stepExecutionIds: stepExecutionIds)
    if let firstFailure { throw firstFailure }
    try transportStore.remove(workflowExecutionId: workflowExecutionId)
  }

  private func run(_ request: BuiltinAddonContainerRequest, invocation: Invocation) async throws -> BuiltinAddonContainerReply {
    try validateControlIsolation(settings: invocation.settings)
    if let sandbox = invocation.sandbox { try validateSandboxControlIsolation(sandbox) }
    try request.validate()
    var policy = invocation.sandbox?.admission
    // The startup reserve belongs to execution. Control workers retain the
    // same pool and wait bound within their own fixed finalization deadline.
    if request.operation != .execute { policy?.minimumRemainingSeconds = 0 }
    return try await SandboxExecutionAdmission.withLease(policy, environment: environment, deadline: request.deadline) {
      try await runAdmitted(request, invocation: invocation)
    }
  }

  /// Everything from bridge setup to reply decoding runs inside the lease.
  private func runAdmitted(_ request: BuiltinAddonContainerRequest, invocation: Invocation) async throws -> BuiltinAddonContainerReply {
    var wireRequest = request
    let nativeBridge: NativeAppleAddonBridge?
    if let input = request.input, AppleGatewayContainerCapability(addonName: input.addon.name).isSupported {
      guard hostPlatform == .darwin else {
        throw AdapterExecutionError(.policyBlocked, "native Apple gateway dependencies require a macOS host")
      }
      let channel = try NativeAddonBridgeChannel.create(workingDirectory: workingDirectory)
      wireRequest.nativeAppleBridgeDirectory = channel.directory.path
      let retryEnvironment = try gatewayWriteRetryEnvironment(input, prefix: "APPLE_GATEWAY_")
      let selectedRunner = nativeAppleGatewayRunner
      let nativeRunner: AppleGatewayRunner = { arguments, environment, deadline in
        try AppleGatewayInvoker(runtimeEnvironment: environment, extraEnvironment: retryEnvironment,
          runnerOverride: selectedRunner).run(arguments: arguments, deadline: deadline, allowNonzeroExit: true)
      }
      nativeBridge = .init(channel: channel, capability: try .init(input: input, workingDirectory: workingDirectory, mounts: invocation.settings.mounts), environment: environment,
        deadline: request.deadline ?? Date().addingTimeInterval(120), runner: nativeRunner)
    } else {
      nativeBridge = nil
    }
    let kaibaBridge: NativeKaibaAddonBridge?
    if let instance = request.kaibaInstance?.instance,
       try KaibaClientFactory().makeClient(instance: instance, environment: environment).endpoint.isLoopback {
      let channel = try NativeAddonBridgeChannel.create(workingDirectory: workingDirectory)
      wireRequest.nativeKaibaBridgeDirectory = channel.directory.path
      kaibaBridge = .init(channel: channel, transport: try .init(instance: instance, environment: environment),
        deadline: request.deadline ?? Date().addingTimeInterval(120))
    } else { kaibaBridge = nil }
    try wireRequest.validate()
    let encoded = try JSONEncoder().encode(wireRequest)
    guard let stdin = String(data: encoded, encoding: .utf8) else {
      throw AdapterExecutionError(.invalidInput, "built-in container input must be UTF-8")
    }
    guard encoded.count <= BuiltinAddonContainerRequest.maximumRecordBytes else {
      throw AdapterExecutionError(.invalidInput, "built-in container request exceeds the record size limit")
    }
    let configuration: LocalProcessConfiguration
    let executionDirectory: SandboxExecutionDirectory?
    if invocation.sandbox != nil {
      try prepareBuiltinAddonContainerState(at: BuiltinAddonContainerTransportStore.workerStateRoot(for: transportRootDirectory))
      let directory = try SandboxExecutionDirectory(parent: transportRootDirectory.deletingLastPathComponent().deletingLastPathComponent())
      executionDirectory = directory
      configuration = try sandboxWorkerConfiguration(invocation: invocation, request: request, directory: directory)
    } else {
      executionDirectory = nil
      configuration = try containerWorkerConfiguration(invocation: invocation)
    }
    defer { withExtendedLifetime(executionDirectory) {} }
    let result: LocalProcessResult
    if nativeBridge != nil || kaibaBridge != nil {
      let processRunner = runner
      result = try await withThrowingTaskGroup(of: LocalProcessResult?.self) { group in
        group.addTask {
          if let nativeBridge { try await nativeBridge.serve() }
          if let kaibaBridge { try await kaibaBridge.serve() }
          return nil
        }
        group.addTask { try await processRunner.run(configuration: configuration, stdin: stdin + "\n", deadline: request.deadline) }
        defer { group.cancelAll() }
        guard let completed = try await group.next(), let output = completed else {
          throw AdapterExecutionError(.invalidOutput, "isolated worker process returned no result")
        }
        return output
      }
    } else {
      result = try await runner.run(configuration: configuration, stdin: stdin + "\n", deadline: request.deadline)
    }
    guard result.terminationStatus == 0 else {
      throw isolatedWorkerExitError(status: result.terminationStatus, deadline: request.deadline,
        subject: "built-in add-on worker")
    }
    guard result.stdout.utf8.count <= BuiltinAddonContainerRequest.maximumRecordBytes,
          JSONLRecordFraming.records(in: result.stdout).count == 1 else {
      throw AdapterExecutionError(.invalidOutput, "built-in worker must return one bounded JSONL record")
    }
    do {
      return try JSONDecoder().decode(BuiltinAddonContainerReply.self, from: Data(result.stdout.utf8))
    } catch {
      throw AdapterExecutionError(.invalidOutput, "invalid built-in worker reply")
    }
  }

  private func containerWorkerConfiguration(invocation: Invocation) throws -> LocalProcessConfiguration {
    let driver: any ContainerRuntimeDriver
    if let executable = invocation.runtimeExecutable {
      let discovery = ContainerRuntimeDiscovery(environment: ["RIELA_CONTAINER_RUNTIME": executable], hostPlatform: hostPlatform)
      guard !discovery.configuredAppleContainerIsUnsupported, let persistedDriver = discovery.configuredDriver() else {
        throw AdapterExecutionError(.policyBlocked, "persisted container runtime is unavailable on this host")
      }
      driver = persistedDriver
    } else {
      driver = try runtimeDriver(settings: invocation.settings)
    }
    let stateRoot = URL(fileURLWithPath: Self.guestStateDirectory, isDirectory: true)
    let hostStateRoot = BuiltinAddonContainerTransportStore.workerStateRoot(for: transportRootDirectory)
    try prepareBuiltinAddonContainerState(at: hostStateRoot)
    var mounts = try resolvedMounts(settings: invocation.settings, driver: driver)
    mounts.append(.init(source: hostStateRoot.path, target: stateRoot.path, readOnly: false))
    let homeRoot = stateRoot.appendingPathComponent("home", isDirectory: true)
    var childEnvironment = try resolveAddonEnvironment(invocation.environmentBindings, runtimeEnvironment: environment)
    childEnvironment["HOME"] = homeRoot.path
    childEnvironment["RIELA_ADDON_STATE_DIR"] = stateRoot.path
    let arguments = driver.runArguments(image: invocation.settings.image, options: .init(
      environment: childEnvironment, mounts: mounts, entrypoint: WorkflowAddonContainerExecution.workerEntrypoint,
      workingDirectory: workingDirectory.path, networkAllowed: invocation.settings.networkPolicy == .egressAllowed,
      readOnlyRootFilesystem: true))
    let executable = driver.executable
    return LocalProcessConfiguration(
      executableURL: URL(fileURLWithPath: executable.hasPrefix("/") ? executable : "/usr/bin/env"),
      arguments: executable.hasPrefix("/") ? arguments : [executable] + arguments, environment: environment,
      unsetEnvironmentKeys: ["RIELA_WORKFLOW_INPUT", "RIELA_WORKFLOW_OUTPUT"], workingDirectoryURL: workingDirectory)
  }

  private func sandboxWorkerConfiguration(invocation: Invocation, request: BuiltinAddonContainerRequest,
                                          directory: SandboxExecutionDirectory) throws -> LocalProcessConfiguration {
    guard var options = invocation.sandbox, let executable = invocation.runtimeExecutable,
          let component = invocation.workerStateComponent, component.count == 64,
          component.allSatisfy({ $0.isHexDigit }) else {
      throw AdapterExecutionError(.policyBlocked, "persisted sandbox worker transport is incomplete")
    }
    let state = BuiltinAddonContainerTransportStore.workerStateRoot(for: transportRootDirectory).appendingPathComponent(component)
    try prepareBuiltinAddonContainerState(at: state)
    if request.operation != .execute {
      options.credentials = []
      options.credentialPaths = []
      options.environment = []
    }
    options.writePaths.append(state.path)
    let launcher = ExecutionSandboxLauncher(environment: environment)
    let worker = URL(fileURLWithPath: executable)
    let explicit = request.operation == .execute
      ? try resolveAddonEnvironment(invocation.environmentBindings, runtimeEnvironment: environment) : [:]
    return try launcher.process(executable: worker,
      arguments: options.backend == .container ? [] : [SandboxNodeWorker.addonCommand], workspace: workingDirectory,
      options: launcher.workerOptions(options, executable: worker), directory: directory, explicitEnvironment: explicit,
      containerExecutable: WorkflowAddonContainerExecution.workerEntrypoint, homeDirectory: state.appendingPathComponent("home"),
      runtimeEnvironment: ["RIELA_ADDON_STATE_DIR": state.path])
  }

  private func validateSandboxControlIsolation(_ options: WorkflowExecutionSandbox) throws {
    let paths = options.readPaths + options.writePaths + options.credentialPaths + options.credentials.map(\.source)
    try BuiltinAddonContainerTransportStore.validateIsolation(mountSources: paths.map { URL(fileURLWithPath: $0) },
      controlDirectory: transportRootDirectory)
  }

  private func runtimeDriver(settings: WorkflowAddonContainerExecution) throws -> any ContainerRuntimeDriver {
    var selectedEnvironment = environment
    if selectedEnvironment["RIELA_CONTAINER_RUNTIME"]?.isEmpty != false, settings.runtime != .auto {
      selectedEnvironment["RIELA_CONTAINER_RUNTIME"] = settings.runtime == .appleContainer ? "container" : settings.runtime.rawValue
    }
    let discovery = ContainerRuntimeDiscovery(environment: selectedEnvironment, hostPlatform: hostPlatform)
    guard !discovery.configuredAppleContainerIsUnsupported else {
      throw AdapterExecutionError(.providerError, "Apple Container is only available on Darwin hosts")
    }
    guard let driver = discovery.configuredDriver() ?? discovery.selectedAvailableDriver() else {
      throw AdapterExecutionError(.providerError, "container runtime is missing; run 'riela setup container' or set RIELA_CONTAINER_RUNTIME")
    }
    return driver
  }

  private func validateControlIsolation(settings: WorkflowAddonContainerExecution) throws {
    let sources = [workingDirectory] + settings.mounts.map {
      $0.source.hasPrefix("/") ? URL(fileURLWithPath: $0.source) : workingDirectory.appendingPathComponent($0.source)
    }
    try BuiltinAddonContainerTransportStore.validateIsolation(mountSources: sources, controlDirectory: transportRootDirectory)
  }

  private func resolvedMounts(settings: WorkflowAddonContainerExecution, driver: any ContainerRuntimeDriver) throws -> [ContainerRuntimeMount] {
    for target in [workingDirectory.path] + settings.mounts.map(\.target) {
      let path = URL(fileURLWithPath: target).standardizedFileURL.path
      guard path != Self.guestStateDirectory, !path.hasPrefix(Self.guestStateDirectory + "/"),
            !Self.guestStateDirectory.hasPrefix(path.hasSuffix("/") ? path : path + "/") else {
        throw AdapterExecutionError(.policyBlocked, "container mount overlaps the reserved worker state directory")
      }
    }
    guard workingDirectory.path != "/", !workingDirectory.path.contains(","), !workingDirectory.path.contains(":") else {
      throw AdapterExecutionError(.policyBlocked, "invalid container workspace mount")
    }
    var mounts = [ContainerRuntimeMount(source: workingDirectory.path, target: workingDirectory.path, readOnly: false)]
    var targets = Set([workingDirectory.path])
    for mount in settings.mounts {
      let sourceURL = mount.source.hasPrefix("/") ? URL(fileURLWithPath: mount.source) : workingDirectory.appendingPathComponent(mount.source)
      let source = sourceURL.resolvingSymlinksInPath().standardizedFileURL.path
      let target = URL(fileURLWithPath: mount.target).standardizedFileURL.path
      var isDirectory: ObjCBool = false
      guard source != "/", !source.contains(","), !source.contains(":"), targets.insert(target).inserted,
            FileManager.default.fileExists(atPath: source, isDirectory: &isDirectory) else {
        throw AdapterExecutionError(.policyBlocked, "invalid, missing, or duplicate addon.container mount")
      }
      guard driver.kind != .appleContainer || isDirectory.boolValue else {
        throw AdapterExecutionError(.policyBlocked, "Apple Container mounts require directory sources")
      }
      mounts.append(.init(source: source, target: target, readOnly: mount.readOnly))
    }
    return mounts
  }
}
