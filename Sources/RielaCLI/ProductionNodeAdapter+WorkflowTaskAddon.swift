import Crypto
import Foundation
import RielaCore
import RielaWorkflowRegistry

protocol GeneratedWorkflowTaskExecuting: Sendable {
  func execute(
    request: GeneratedWorkflowTaskRequest,
    configuration: GeneratedWorkflowTaskConfiguration,
    workingDirectory: URL
  ) async throws -> GeneratedWorkflowTaskResult
}

struct GeneratedWorkflowTaskRequest: Equatable, Sendable {
  var title: String
  var prompt: String
}

struct GeneratedWorkflowTaskConfiguration: Equatable, Sendable {
  var executionBackend: NodeExecutionBackend
  var model: String
  var workflowIdPrefix: String
  var maxPromptBytes: Int
}

struct GeneratedWorkflowTaskResult: Equatable, Sendable {
  var workflowId: String
  var workflowDirectory: String
  var overwritten: Bool
  var runResult: WorkflowRunResult
}

protocol GeneratedWorkflowTaskRegistering: Sendable {
  func register(bundle: URL, workingDirectory: URL) throws -> GeneratedWorkflowTaskRegistration
}

struct GeneratedWorkflowTaskRegistration: Equatable, Sendable {
  var workflowDirectory: String
  var overwritten: Bool
}

protocol GeneratedWorkflowTaskRunning: Sendable {
  func run(workflowId: String, workingDirectory: URL) async throws -> WorkflowRunResult
}

struct MutableGeneratedWorkflowTaskRegistrar: GeneratedWorkflowTaskRegistering {
  func register(bundle: URL, workingDirectory: URL) throws -> GeneratedWorkflowTaskRegistration {
    let mutation = try WorkflowRegistryService().register(
      input: bundle,
      overwrite: true,
      workingDirectory: workingDirectory.path
    )
    guard mutation.accepted, let workflow = mutation.workflow else {
      throw AdapterExecutionError(.providerError, "generated workflow registration returned no workflow")
    }
    return GeneratedWorkflowTaskRegistration(
      workflowDirectory: workflow.workflowDirectory,
      overwritten: mutation.overwritten
    )
  }
}

struct CommandGeneratedWorkflowTaskRunner: GeneratedWorkflowTaskRunning {
  var command: WorkflowRunCommand
  var mockScenarioPath: String?

  init(
    command: WorkflowRunCommand = WorkflowRunCommand(),
    mockScenarioPath: String? = nil
  ) {
    self.command = command
    self.mockScenarioPath = mockScenarioPath
  }

  func run(workflowId: String, workingDirectory: URL) async throws -> WorkflowRunResult {
    let result = await command.run(WorkflowRunOptions(
      target: workflowId,
      resolution: WorkflowResolutionOptions(
        workflowName: workflowId,
        scope: .user,
        workingDirectory: workingDirectory.path
      ),
      mockScenarioPath: mockScenarioPath,
      output: .json,
      workingDirectory: workingDirectory.path,
      explicitWorkingDirectory: true
    ))
    guard result.exitCode == .success else {
      let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      throw AdapterExecutionError(
        .providerError,
        detail.isEmpty ? "generated workflow execution failed" : detail
      )
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(WorkflowRunResult.self, from: Data(result.stdout.utf8))
  }
}

struct DefaultGeneratedWorkflowTaskExecutor: GeneratedWorkflowTaskExecuting {
  var registrar: any GeneratedWorkflowTaskRegistering
  var runner: any GeneratedWorkflowTaskRunning
  var scaffolder: WorkflowBundleScaffolder
  var temporaryDirectory: @Sendable () -> URL

  init(
    registrar: any GeneratedWorkflowTaskRegistering = MutableGeneratedWorkflowTaskRegistrar(),
    runner: any GeneratedWorkflowTaskRunning = CommandGeneratedWorkflowTaskRunner(),
    scaffolder: WorkflowBundleScaffolder = WorkflowBundleScaffolder(),
    temporaryDirectory: @escaping @Sendable () -> URL = {
      FileManager.default.temporaryDirectory
        .appendingPathComponent("riela-generated-workflow-\(UUID().uuidString.lowercased())", isDirectory: true)
    }
  ) {
    self.registrar = registrar
    self.runner = runner
    self.scaffolder = scaffolder
    self.temporaryDirectory = temporaryDirectory
  }

  func execute(
    request: GeneratedWorkflowTaskRequest,
    configuration: GeneratedWorkflowTaskConfiguration,
    workingDirectory: URL
  ) async throws -> GeneratedWorkflowTaskResult {
    let staging = temporaryDirectory().standardizedFileURL
    defer { try? FileManager.default.removeItem(at: staging) }
    let workflowId = generatedWorkflowId(request: request, configuration: configuration)
    _ = try scaffolder.create(
      at: staging,
      specification: WorkflowBundleScaffoldSpecification(
        workflowId: workflowId,
        description: request.title,
        nodeId: "task-worker",
        executionBackend: configuration.executionBackend,
        model: configuration.model,
        modelFreeze: true,
        prompt: request.prompt,
        maxLoopIterations: 1,
        nodeTimeoutMs: 180_000
      )
    )
    let registration = try registrar.register(bundle: staging, workingDirectory: workingDirectory)
    let runResult = try await runner.run(workflowId: workflowId, workingDirectory: workingDirectory)
    guard runResult.status == .completed, runResult.exitCode == 0 else {
      throw AdapterExecutionError(.providerError, "generated workflow did not complete")
    }
    return GeneratedWorkflowTaskResult(
      workflowId: workflowId,
      workflowDirectory: registration.workflowDirectory,
      overwritten: registration.overwritten,
      runResult: runResult
    )
  }
}

extension BuiltinWorkflowAddonResolver {
  func executeWorkflowCreateRegisterRun(
    _ input: WorkflowAddonExecutionInput
  ) async throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(
        .policyBlocked,
        "unsupported riela/workflow-create-register-run version '\(input.addon.version ?? "")'"
      )
    }
    let configuration = try generatedWorkflowTaskConfiguration(input.addon.config ?? [:])
    let request = try generatedWorkflowTaskRequest(input.resolvedInputPayload, maxPromptBytes: configuration.maxPromptBytes)
    let result = try await workflowTaskExecutor.execute(
      request: request,
      configuration: configuration,
      workingDirectory: workingDirectory
    )

    var payload = input.resolvedInputPayload
    let workflowOutput = result.runResult.rootOutput ?? [:]
    payload["status"] = .string("ok")
    payload["addon"] = .string(input.addon.name)
    payload["stepId"] = .string(input.stepId)
    payload["generatedWorkflowId"] = .string(result.workflowId)
    payload["generatedWorkflowDirectory"] = .string(result.workflowDirectory)
    payload["generatedWorkflowRegistered"] = .bool(true)
    payload["generatedWorkflowOverwritten"] = .bool(result.overwritten)
    payload["generatedWorkflowExecuted"] = .bool(true)
    payload["generatedWorkflowSessionId"] = .string(result.runResult.session.sessionId)
    payload["generatedWorkflowOutput"] = .object(workflowOutput)
    if let reply = nonEmptyString(workflowOutput["replyText"]) ?? nonEmptyString(workflowOutput["text"]) {
      payload["replyText"] = .string(reply)
    }

    var when: [String: Bool] = ["always": true]
    for (key, value) in payload {
      if case let .bool(flag) = value {
        when[key] = flag
      }
    }
    return AdapterExecutionOutput(
      provider: "riela-builtin-addon",
      model: input.addon.name,
      promptText: "",
      completionPassed: true,
      when: when,
      payload: payload
    )
  }
}

private func generatedWorkflowTaskConfiguration(
  _ config: JSONObject
) throws -> GeneratedWorkflowTaskConfiguration {
  guard boolValue(config["allowWorkflowCreation"]) == true else {
    throw AdapterExecutionError(
      .policyBlocked,
      "riela/workflow-create-register-run requires config.allowWorkflowCreation=true"
    )
  }
  guard let backendValue = nonEmptyString(config["executionBackend"]),
    let backend = NodeExecutionBackend(rawValue: backendValue)
  else {
    throw AdapterExecutionError(
      .policyBlocked,
      "riela/workflow-create-register-run config.executionBackend is invalid"
    )
  }
  guard let model = nonEmptyString(config["model"]), model.utf8.count <= 128 else {
    throw AdapterExecutionError(
      .policyBlocked,
      "riela/workflow-create-register-run config.model is required and must not exceed 128 bytes"
    )
  }
  let prefix = nonEmptyString(config["workflowIdPrefix"]) ?? "generated-task"
  guard prefix.range(of: #"^[a-z0-9][a-z0-9-]{1,31}$"#, options: .regularExpression) != nil else {
    throw AdapterExecutionError(
      .policyBlocked,
      "riela/workflow-create-register-run config.workflowIdPrefix must be 2-32 lowercase letters, numbers, or dashes"
    )
  }
  let maxPromptBytes = intValue(config["maxPromptBytes"]) ?? 65_536
  guard (1...262_144).contains(maxPromptBytes) else {
    throw AdapterExecutionError(
      .policyBlocked,
      "riela/workflow-create-register-run config.maxPromptBytes must be between 1 and 262144"
    )
  }
  return GeneratedWorkflowTaskConfiguration(
    executionBackend: backend,
    model: model,
    workflowIdPrefix: prefix,
    maxPromptBytes: maxPromptBytes
  )
}

private func generatedWorkflowTaskRequest(
  _ payload: JSONObject,
  maxPromptBytes: Int
) throws -> GeneratedWorkflowTaskRequest {
  guard boolValue(payload["run_workflow"]) == true, boolValue(payload["llm_only"]) != true else {
    throw AdapterExecutionError(
      .policyBlocked,
      "riela/workflow-create-register-run requires run_workflow=true and llm_only=false"
    )
  }
  let nestedPayload = objectValue(payload["payload"]) ?? [:]
  guard let task = objectValue(payload["workflowTask"]) ?? objectValue(nestedPayload["workflowTask"]) else {
    throw AdapterExecutionError(
      .invalidOutput,
      "run_workflow=true requires workflowTask with title and prompt"
    )
  }
  guard let title = nonEmptyString(task["title"]), title.utf8.count <= 256 else {
    throw AdapterExecutionError(.invalidOutput, "workflowTask.title is required and must not exceed 256 bytes")
  }
  guard let prompt = nonEmptyString(task["prompt"]), prompt.utf8.count <= maxPromptBytes else {
    throw AdapterExecutionError(
      .invalidOutput,
      "workflowTask.prompt is required and exceeds the configured byte limit"
    )
  }
  return GeneratedWorkflowTaskRequest(title: title, prompt: prompt)
}

func generatedWorkflowId(
  request: GeneratedWorkflowTaskRequest,
  configuration: GeneratedWorkflowTaskConfiguration
) -> String {
  let digestInput = [
    request.title,
    request.prompt,
    configuration.executionBackend.rawValue,
    configuration.model
  ].joined(separator: "\u{0}")
  let digest = SHA256.hash(data: Data(digestInput.utf8))
    .prefix(6)
    .map { String(format: "%02x", $0) }
    .joined()
  let suffixLength = digest.count + 2
  let maximumSlugLength = max(1, 64 - configuration.workflowIdPrefix.count - suffixLength)
  let slug = workflowTaskSlug(request.title, maximumLength: maximumSlugLength)
  return "\(configuration.workflowIdPrefix)-\(slug)-\(digest)"
}

private func workflowTaskSlug(_ value: String, maximumLength: Int) -> String {
  var slug = ""
  var needsDash = false
  for scalar in value.lowercased().unicodeScalars {
    let accepted = (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57)
    if accepted {
      if needsDash, !slug.isEmpty, slug.count < maximumLength {
        slug.append("-")
      }
      if slug.count < maximumLength {
        slug.unicodeScalars.append(scalar)
      }
      needsDash = false
    } else {
      needsDash = true
    }
    if slug.count >= maximumLength { break }
  }
  while slug.last == "-" { slug.removeLast() }
  return slug.isEmpty ? "task" : slug
}
