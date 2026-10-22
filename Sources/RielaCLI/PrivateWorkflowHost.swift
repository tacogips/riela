import Foundation
import RielaAdapters
import RielaAddonSupport
import RielaCore

struct PrivateWorkflowHost {
  var environment: [String: String]
  var workingDirectory: URL
  var runner: any LocalProcessRunning
  var directoryParent: URL?

  func execute(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1",
          let sandbox = input.addon.sandbox, sandbox.backend == .container,
          sandbox.ephemeralHome, input.addon.container == nil else {
      throw AdapterExecutionError(.policyBlocked, "private-workflow requires an ephemeral container sandbox")
    }
    try sandbox.validate()
    let variables = try addonVariables(for: input)
    guard case let .object(config) = try renderAddonConfig(.object(input.addon.config ?? [:]), variables: variables) else {
      throw PrivateWorkflowPlan.invalid()
    }
    let plan = try PrivateWorkflowPlan(config: config)
    let projectedEnvironment = try resolveAddonEnvironment(input.addon.env, runtimeEnvironment: environment)
    try PrivateWorkflowPlan.validateEnvironment(projectedEnvironment)
    var credentials: [SandboxRuntimeCredential] = []
    for name in sandbox.credentialEnvironment.keys.sorted() {
      guard projectedEnvironment[name] == nil, let value = environment[name], !value.isEmpty,
            value.utf8.count <= 1_000_000 else { throw PrivateWorkflowPlan.invalid() }
      credentials.append(.init(homePath: sandbox.credentialEnvironment[name]!, value: value))
    }
    let deadline = min(context.deadline ?? .distantFuture,
      Date().addingTimeInterval(TimeInterval(plan.timeoutSeconds ?? 600)))
    guard deadline > Date() else { throw AdapterExecutionError(.timeout, "private workflow deadline expired") }
    let request = PrivateWorkflowRequest(plan: plan, deadline: deadline,
      environment: projectedEnvironment, credentials: credentials)
    let bytes = try JSONEncoder().encode(request)
    guard bytes.count <= BuiltinAddonContainerRequest.maximumRecordBytes, let stdin = String(data: bytes, encoding: .utf8) else {
      throw PrivateWorkflowPlan.invalid()
    }
    // Container client configuration receives runtime controls, never source or
    // provider credentials. Selected values travel only on attached worker stdin.
    let controls: Set<String> = ["HOME", "PATH", "TMPDIR", "RIELA_SANDBOX_WORKER_EXECUTABLE",
      "DOCKER_HOST", "DOCKER_CONTEXT", "CONTAINER_HOST"]
    let launcher = ExecutionSandboxLauncher(environment: environment.filter {
      controls.contains($0.key) || $0.key.hasPrefix("RIELA_CONTAINER_")
    })
    let executable = try launcher.workerExecutable()
    let directory = try SandboxExecutionDirectory(parent: directoryParent ?? FileManager.default.temporaryDirectory)
    defer { withExtendedLifetime(directory) {} }
    var configuration = try launcher.process(executable: executable, arguments: [PrivateWorkflowWorker.command],
      workspace: workingDirectory, options: launcher.workerOptions(sandbox, executable: executable), directory: directory,
      explicitEnvironment: [:], containerExecutable: "/opt/riela/riela", homeDirectory: directory.root.appendingPathComponent("home"))
    guard let index = configuration.arguments.firstIndex(of: "--tmpfs"), index + 1 < configuration.arguments.count else {
      throw PrivateWorkflowPlan.invalid()
    }
    configuration.arguments[index + 1] = "/tmp:rw,nosuid,nodev,noexec,size=256m"
    let records = SandboxNodeRecordCollector(privateOutput: true)
    let result: LocalProcessResult
    do {
      result = try await EphemeralContainerNodeProcess(runner: runner).run(configuration: configuration,
        stdin: stdin + "\n", deadline: deadline) { event in
          if event.stream == .stdout { _ = records.accept(event.line) }
        }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw AdapterExecutionError(deadline <= Date() ? .timeout : .providerError, "private workflow transport failed")
    }
    guard result.terminationStatus == 0 else {
      throw AdapterExecutionError(.policyBlocked, "private workflow worker did not complete")
    }
    let terminal = try records.result()
    if let failure = terminal.failure {
      let source = try failure.executionError()
      throw AdapterExecutionError(source.code, "private workflow execution failed")
    }
    guard let output = terminal.output, terminal.vendorSessionId == nil, output.promptText.isEmpty, output.usage == nil else {
      throw AdapterExecutionError(.invalidOutput, "private workflow returned invalid result metadata")
    }
    return try SandboxNodeWorker.privateOutput(output, contract: .init(jsonSchema: plan.outputSchema))
  }
}
