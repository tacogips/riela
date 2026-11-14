import Foundation
import RielaCore

/// Resolves callee workflows for live cross-workflow dispatch through the same
/// scope machinery the CLI uses for the caller: the caller's own resolution
/// context first (for example a --workflow-definition-dir root), then the
/// project scope, user scope, and installed packages.
public struct FileSystemWorkflowCalleeResolver: WorkflowCalleeResolving {
  public var resolver: any WorkflowBundleResolving
  public var baseResolution: WorkflowResolutionOptions
  var taskContext: TaskPlacementExecutionContext?

  public init(
    resolver: any WorkflowBundleResolving = FileSystemWorkflowBundleResolver(),
    baseResolution: WorkflowResolutionOptions
  ) {
    self.resolver = resolver
    self.baseResolution = baseResolution
    self.taskContext = nil
  }

  init(
    resolver: any WorkflowBundleResolving,
    baseResolution: WorkflowResolutionOptions,
    taskContext: TaskPlacementExecutionContext?
  ) {
    self.resolver = resolver
    self.baseResolution = baseResolution
    self.taskContext = taskContext
  }

  public func resolveCallee(workflowId: String) async throws -> ResolvedWorkflowCallee {
    let original = try resolveBundle(workflowId: workflowId)
    let bundle = try taskContext.map {
      try WorkflowRunCommand().applyingTaskPlacement($0, to: original)
    } ?? original
    return ResolvedWorkflowCallee(workflow: bundle.workflow, nodePayloads: bundle.nodePayloads)
  }

  func resolveBundle(workflowId: String) throws -> ResolvedWorkflowBundle {
    if let taskContext {
      guard let bundle = taskContext.bundles[workflowId] else {
        throw WorkflowResolutionError.notFound(workflowId, ["callee was not admitted by task dispatch"])
      }
      return bundle
    }
    var failures: [String] = []
    for candidate in candidateResolutions(workflowId: workflowId) {
      let bundle: ResolvedWorkflowBundle
      do {
        bundle = try resolver.resolve(candidate)
      } catch {
        failures.append(workflowResolutionErrorDescription(error))
        continue
      }
      guard bundle.workflow.workflowId == workflowId else {
        failures.append(
          "\(bundle.workflowDirectory) resolves workflowId '\(bundle.workflow.workflowId)', expected '\(workflowId)'"
        )
        continue
      }
      return bundle
    }
    throw WorkflowResolutionError.notFound(workflowId, failures)
  }

  private func candidateResolutions(workflowId: String) -> [WorkflowResolutionOptions] {
    var candidates = [
      WorkflowResolutionOptions(
        workflowName: workflowId,
        scope: baseResolution.scope,
        workflowDefinitionDir: baseResolution.workflowDefinitionDir,
        workingDirectory: baseResolution.workingDirectory
      )
    ]
    if baseResolution.workflowDefinitionDir != nil || baseResolution.scope != .auto {
      candidates.append(WorkflowResolutionOptions(
        workflowName: workflowId,
        scope: .auto,
        workingDirectory: baseResolution.workingDirectory
      ))
    }
    return candidates
  }
}
