import Foundation
import RielaCore
import RielaGraphQL
import RielaWorkflowRegistry

/// The Swift embedding facade for Riela (design 2.6).
///
/// This is the only supported library surface: six entry points, each
/// delegating to the same command the CLI runs, so an embedder and a shell get
/// identical behaviour. `SurfaceParityLibraryTests` reads this file and
/// asserts its `public func` names are exactly the catalog's `library`
/// bindings, so an entry point cannot be added here without a catalog row —
/// or documented in a skill without existing.
public struct RielaLibrary: Sendable {
  public var workingDirectory: String
  public var scope: WorkflowScope
  public var workflowDefinitionDir: String?
  public var sessionStore: String?

  public init(
    workingDirectory: String = FileManager.default.currentDirectoryPath,
    scope: WorkflowScope = .auto,
    workflowDefinitionDir: String? = nil,
    sessionStore: String? = nil
  ) {
    self.workingDirectory = workingDirectory
    self.scope = scope
    self.workflowDefinitionDir = workflowDefinitionDir
    self.sessionStore = sessionStore
  }

  /// Runs a workflow to completion, exactly as `riela workflow run` does.
  public func executeWorkflow(
    _ workflowName: String,
    variables: String? = nil,
    mockScenarioPath: String? = nil,
    maxSteps: Int? = nil
  ) async -> CLICommandResult {
    await WorkflowRunCommand().run(WorkflowRunOptions(
      target: workflowName,
      resolution: resolution(workflowName: workflowName),
      variables: variables,
      mockScenarioPath: mockScenarioPath,
      output: .json,
      maxSteps: maxSteps,
      sessionStore: sessionStore,
      workingDirectory: workingDirectory
    ))
  }

  /// Resumes a persisted session, exactly as `riela session resume` does.
  public func resumeSession(
    _ sessionId: String,
    mockScenarioPath: String? = nil,
    maxSteps: Int? = nil
  ) async -> CLICommandResult {
    await SessionResumeCommand().run(SessionResumeOptions(
      sessionId: sessionId,
      output: .json,
      scope: scope,
      workflowDefinitionDir: workflowDefinitionDir,
      workingDirectory: workingDirectory,
      mockScenarioPath: mockScenarioPath,
      sessionStore: sessionStore,
      maxSteps: maxSteps
    ))
  }

  /// Reruns a persisted session from a step, exactly as `riela session rerun`
  /// does, producing the same lineage record.
  public func rerunSession(
    _ sessionId: String,
    fromStepId stepId: String,
    mockScenarioPath: String? = nil
  ) async -> CLICommandResult {
    await SessionRerunCommand().run(SessionRerunOptions(
      sessionId: sessionId,
      stepId: stepId,
      output: .json,
      scope: scope,
      workflowDefinitionDir: workflowDefinitionDir,
      workingDirectory: workingDirectory,
      mockScenarioPath: mockScenarioPath,
      sessionStore: sessionStore
    ))
  }

  /// Projects a workflow bundle, exactly as `riela workflow inspect` does.
  public func inspectWorkflow(
    _ workflowName: String,
    structure: Bool = false
  ) async -> CLICommandResult {
    await WorkflowInspectCommand().run(WorkflowInspectOptions(
      workflowName: workflowName,
      resolution: resolution(workflowName: workflowName),
      output: .json,
      structure: structure
    ))
  }

  /// Reads a persisted session, exactly as `riela session status` does.
  public func sessionView(_ sessionId: String) async -> CLICommandResult {
    await SessionInspectionCommand().run(CLICommandOptions(
      scope: "session",
      command: "status",
      target: sessionId,
      arguments: sessionStore.map { ["--session-store", $0] } ?? [],
      output: .json
    ))
  }

  /// Executes a control-plane GraphQL document in this process, through the
  /// same composite executor `riela graphql document` uses.
  public func executeGraphQLDocument(
    _ query: String,
    variables: JSONObject = [:],
    operationName: String? = nil
  ) async -> GraphQLDocumentExecutionResponse {
    let executor = CompositeGraphQLDocumentExecutor(
      workflowRegistry: WorkflowRegistryGraphQLDocumentExecutor(
        localProvider: FileWorkflowRegistryGraphQLProvider(workingDirectory: workingDirectory)
      ),
      fallback: SessionControlGraphQLDocumentExecutor(
        provider: RielaSessionControlProvider(
          workingDirectory: workingDirectory,
          sessionStore: sessionStore,
          scope: scope,
          workflowDefinitionDir: workflowDefinitionDir
        ),
        next: RoutineGraphQLDocumentExecutor(
          provider: FileRoutineGraphQLProvider(
            workingDirectory: workingDirectory,
            environment: CLIRuntimeEnvironment.mergedProcessEnvironment()
          )
        )
      )
    )
    return await executor.execute(GraphQLDocumentRequest(
      query: query,
      variables: variables,
      operationName: operationName,
      environment: CLIRuntimeEnvironment.mergedProcessEnvironment(),
      isLocallyTrusted: true,
      localWorkingDirectory: workingDirectory
    ))
  }

  private func resolution(workflowName: String) -> WorkflowResolutionOptions {
    WorkflowResolutionOptions(
      workflowName: workflowName,
      scope: scope,
      workflowDefinitionDir: workflowDefinitionDir,
      workingDirectory: workingDirectory
    )
  }
}
