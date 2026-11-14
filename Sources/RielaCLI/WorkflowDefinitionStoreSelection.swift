import Foundation
import RielaCore
import RielaWorkflowRegistry

enum WorkflowDefinitionStoreSelection {
  static func rootWithHead(
    workflowName: String,
    sessionStore: String?,
    scope: WorkflowScope,
    workingDirectory: String,
    environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment()
  ) throws -> String? {
    try WorkflowDefinitionStoreRoots.rootWithHead(
      workflowName: workflowName, sessionStore: sessionStore, scope: scope,
      workingDirectory: workingDirectory, environment: environment
    )
  }

  static func candidateRoots(
    sessionStore: String?,
    scope: WorkflowScope,
    workingDirectory: String,
    environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment()
  ) -> [String] {
    WorkflowDefinitionStoreRoots.candidateRoots(
      sessionStore: sessionStore, scope: scope, workingDirectory: workingDirectory, environment: environment
    )
  }

  static func seedRoot(
    sessionStore: String?,
    resolution: WorkflowResolutionOptions,
    fileBundle: ResolvedWorkflowBundle,
    environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment()
  ) -> String {
    let persisted = CLIWorkflowSessionResolution.resolutionForPersistence(
      resolution: resolution,
      resolvedSourceScope: fileBundle.sourceScope
    )
    return WorkflowDefinitionStoreRoots.normalizedRoot(
      WorkflowDefinitionStoreRoots.resolveRootDirectory(
        sessionStore: sessionStore,
        scope: persisted.scope,
        workingDirectory: resolution.workingDirectory,
        environment: environment
      ),
      workingDirectory: resolution.workingDirectory
    )
  }

}
