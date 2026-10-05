import Foundation
import RielaCore

extension WorkflowRunCommand {
  func runRemote(endpoint: String, options: WorkflowRunOptions) async throws -> CLICommandResult {
    if options.fromRegistry {
      throw CLIUsageError("workflow run --from-registry is local-only and cannot be combined with --endpoint")
    }
    if options.mockScenarioPath != nil {
      throw CLIUsageError("--mock-scenario cannot be combined with --endpoint")
    }
    if options.supervisorMode {
      throw CLIUsageError("--supervisor-mode is currently supported only for local workflow runs")
    }
    let variables = try parseVariables(options.variables, workingDirectory: options.workingDirectory)
    let nodePatch = try options.nodePatch.map { try jsonLoader.object(from: $0, workingDirectory: options.workingDirectory) }
    let environment = CLIRuntimeEnvironment.mergedProcessEnvironment()
    let configuredAuthTokenEnv = nonEmptyString(options.authTokenEnv)
    let authTokenEnv = configuredAuthTokenEnv ?? "RIELA_API_KEY"
    let authToken = nonEmptyString(options.authToken)
      ?? nonEmptyString(environment[authTokenEnv])
    let managerSessionId = nonEmptyString(environment["RIELA_MANAGER_SESSION_ID"])
    let request = WorkflowRemoteRunRequest(
      workflowName: options.target,
      instanceIdentity: options.instance,
      runtimeVariables: variables,
      nodePatch: nodePatch,
      maxSteps: options.maxSteps,
      maxConcurrency: options.maxConcurrency,
      maxLoopIterations: options.maxLoopIterations,
      disableDefaultLoopGuard: options.disableDefaultLoopGuard,
      defaultTimeoutMs: options.defaultTimeoutMs,
      timeoutMs: options.timeoutMs,
      authToken: authToken,
      authTokenEnv: authTokenEnv,
      managerSessionId: managerSessionId
    )
    let result = try await graphQLTransport.executeWorkflow(endpoint: endpoint, request: request)
    return CLICommandResult(
      exitCode: CLIExitCode(rawValue: result.exitCode) ?? .failure,
      stdout: try renderRemoteRunResult(result, output: options.output)
    )
  }

  func parseVariables(_ reference: String?, workingDirectory: String) throws -> JSONObject {
    guard let reference else {
      return [:]
    }
    return try jsonLoader.object(from: reference, workingDirectory: workingDirectory)
  }

  func renderRemoteRunResult(_ result: WorkflowRemoteRunResult, output: WorkflowOutputFormat) throws -> String {
    switch output {
    case .json:
      return try jsonString(result)
    case .jsonl:
      return try jsonString(WorkflowRemoteRunResultRecord(result: result))
    case .text, .table:
      return "run session: \(result.sessionId)\nstatus: \(result.status)\nnodeExecutions: \(result.nodeExecutions)\n"
    }
  }

}
